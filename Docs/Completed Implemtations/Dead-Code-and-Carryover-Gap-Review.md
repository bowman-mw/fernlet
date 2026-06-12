# Dead Code & Carryover-Gap Review

**Scope:** Static review of the Swift sources in the provided snapshot to find (a) dead/deprecated files, types, and functions, and (b) functionality that existed in `MeshLobbyView` and the pre–disposable-camera flow but was *not* carried into the new `ConnectView` / `DisposableCameraView` surface.

**Method:** Reference-count pass over every top-level declaration (an identifier appearing only at its own declaration site = unused), then manual tracing of each candidate's call graph, cross-checked against `Life-Tab-Redesign-Implementation-Plan.md` to separate *intentional* removals from *accidental* gaps.

> ## Post-cleanup status
> This review is retained as historical analysis. The legacy `MeshLobbyView`, concrete `MultipeerSession`, standalone `FriendPhotoSharingService`, and `FriendPhotoCacheStore` have been removed. Live photo payloads, cache storage, image helpers, and review UI now live under `Proximity/Wire/` and `Proximity/Photos/`. The active `DisposableCameraView` routes captures through `MeshNetworkManager.addPhoto(_:)`, presents `MeshAdmissionPromptSheet`, surfaces `meshError`, exposes open/closed session state, and wires removal proposals and seconds. The carryover gaps in §3 are resolved.

> ## ⚠️ Snapshot caveat — read first
> `DisposableCameraView` is referenced at `ConnectView.swift:22` but **its declaration is not in the provided files.** It exists in your repo (otherwise `ConnectView` would not compile); it just wasn't included here. Several items below are in-session controls that *might* be wired inside `DisposableCameraView`. Every such item is tagged **[verify in DisposableCameraView]**. Do not delete those until checked against that file. Everything *not* tagged is verified dead against the full snapshot.

---

## 1. TL;DR

| Cluster | Verdict | Risk to remove |
|---|---|---|
| `MeshLobbyView` (whole file) | **Dead** — zero references | None |
| Old standalone photo share: `FriendPhotoShareView` struct + `FriendPhotoSharingService` + `FriendPhotoCacheStore` | **Dead** — plan explicitly deprecated it | Low |
| Trainer *role* feature: `TrainerProximityService`, `TrainerDisclosureCardModel`, `TrainerNutritionistExportBundle`, instructor/client session API | **Dead** — abandoned feature | Low *(after confirming the feature is shelved)* |
| Lobby-browse manager API (`startLobby`/`stopLobby`/`joinMesh` + lobby arrays) | **Dead** — plan dropped the browse list | Low–med |
| Workshop / texture data subsystem (`WorkshopData`, `TextureEntry`, `TextureTag`, `addTexture`) | **Dead at UI**, still persisted | Med *(serialization migration)* |
| 5 isolated dead views/enums | **Dead** | None |
| **Functionality not carried over** (admission, mesh-close, error surfacing, removal vote, `addPhoto` reuse) | **Gaps** — see §3 | n/a — these need *re-wiring*, not deletion |

The headline correctness item is **§3.1 (`addPhoto` reuse)** — if the camera doesn't route through `addPhoto`, the per-session photo quota and group-key encryption are silently bypassed.

---

## 2. Dead code — safe to remove

### 2.1 `MeshLobbyView.swift` — delete the file

`MeshLobbyView` (`MeshLobbyView.swift:4`) has zero references anywhere. It was fully replaced by `FriendsView` (`ConnectView.swift`) + `DisposableCameraView`. Deleting the file is safe.

It pulled in two dependents; handle them as follows:

- **`FriendPhotoTile`** — *keep.* Also used by the live `FriendPhotoReviewSheet` (`FriendPhotoShareView.swift:837`), which `ConnectView` presents.
- **`MeshAdmissionPromptSheet`** (`MeshAdmissionPromptSheet.swift`) — **do not delete.** Its only caller is the dead `MeshLobbyView` (`:33`), so it *looks* orphaned — but the redesign plan explicitly says to retain the admission prompt for the token-based rejoin path (plan B‑DEC‑3 / lines 122, 128). It is currently a sheet with no host. See §3.2: it should be re-wired, not removed.

### 2.2 Old standalone photo-share cluster

The plan (line 192) says: *"Route everything through `MeshNetworkManager` (deprecate the standalone `FriendPhotoSharingService` for this surface)."* That deprecation is now complete in fact — the standalone path is no longer reachable:

| Symbol | Location | Why dead |
|---|---|---|
| `FriendPhotoShareView` (struct) | `FriendPhotoShareView.swift:542` | Zero references |
| `FriendPhotoSharingService` | `FriendPhotoShareView.swift:283` | Only instantiated by `FriendPhotoShareView` (`:547`, `:556`) |
| `FriendPhotoCacheStore` | `FriendPhotoShareView.swift:155` | Only used by `FriendPhotoSharingService` (`:290`, `:294`) |

**Keep everything else in that file** — it is load-bearing for the new flow: `FriendPhotoPayload`, `FriendPhotoSessionParticipant`, `FriendPhotoSessionMetadata`, `FriendPhotoManifestEntry`, `FriendPhotoManifestPayload`, `FriendPhotoRequestPayload`, `MeshPhotoCacheStore` (this is the live cache, distinct from the dead `FriendPhotoCacheStore`), `FriendPhotoTile`, `FriendPhotoReviewSheet`, `FriendPhotoLibrarySaver`, and the `UIImage` extension. After removal the file is mostly model/cache types and the live review UI; consider renaming it to reflect that it's no longer a "share view."

> Note: `FriendPhotoSharingService` is the only place that instantiates the legacy transport `MultipeerSession()` (`:304`). `MultipeerSession` the *class* still stays — `ProximityCoordinator` depends on its nested types (`MultipeerSession.State/.InboundMessage/.PendingInvite/.defaultServiceType`). After this removal, confirm the transport is still instantiated through the live `MeshMultipeerSession`/`PeerChannelTransport` path (it is, via `MeshNetworkManager.meshSession`).

### 2.3 Trainer *role* feature — dead, but untangle it from the live audit layer

This is the one place where "delete everything named `Trainer*`" would break the build. The name spans **two unrelated things**:

**(a) The instructor/client *feature* — dead.** Remove (after confirming it's shelved):

| Symbol | Location | Why dead |
|---|---|---|
| `TrainerProximityService` | `TrainerProximityService.swift` (whole file) | Zero references |
| `TrainerDisclosureCardModel` (+ `make`) | `TrainerAuditLog.swift:84` | Only used by `TrainerProximityService` |
| `TrainerNutritionistExportBundle` | `LocalFernletRepository.swift:692` | Zero references |
| `startAsInstructor(name:)` | `MeshNetworkManager.swift:321` | Zero callers |
| `startAsClient()` | `MeshNetworkManager.swift:326` | Zero callers |
| `role` property + `TrainerMeshRole` | `MeshNetworkManager.swift:165` | Only set by the two dead methods above; always `nil` at runtime |
| `role` switch | `MeshNetworkManager.swift:786–792` | Always hits `case nil` |
| `trainerAttachments` + handler | `:162`, insert at `:664–665` | Write-only: received & stored, **no view reads it** |
| Discovery-info role branches | `MeshNetworkManager.swift:828–836` | `role` always `nil`; only the `case nil` branch runs |

**(b) The proximity trust/audit *infrastructure* — alive, keep.** Despite the `Trainer*` naming, these are the connection-inspector audit trail and trust policy used for *all* proximity connections:

- `ProximityTrustPolicy` (`TrainerAuditLog.swift`) — conformed by `FriendSessionTrustPolicy` and `ProximityTrustVault`; `FernletStore` exposes matching vault facade methods.
- `ProximityTrustedPeerRecord` (`TrainerAuditLog.swift:3`) — used by `FriendListView`, `ProximityTrustVault`, `FernletStore`, repositories.
- `TrainerAuditEvent` (`TrainerAuditLog.swift:40`) + `recordTrainerAudit(_:)` — called throughout `ProximityCoordinator` (connect/disconnect/distance events) and stored by `ProximityTrustVault`.

**Recommendation:** keep `TrainerAuditLog.swift` (it's misnamed — it's really proximity trust + audit). After deleting (a), consider renaming the surviving types `TrainerAuditEvent → ProximityAuditEvent` and the file `TrainerAuditLog.swift → ProximityTrustLog.swift` to kill the misleading association. This is optional cleanup, not required for correctness.

### 2.4 Lobby-browse manager API

The plan (line 192) says: *"Drop the lobby browse list … One Join button (no separate create/find)."* The Connect tab now drives everything through `startJoin()` (`ContentView.swift:382`), which sets `isProximityJoin = true`. As a result the entire non-proximity discovery path is unreachable.

Remove:

| Symbol | Location | Notes |
|---|---|---|
| `startLobby()` | `MeshNetworkManager.swift:356` | Only the dead `MeshLobbyView` called it |
| `stopLobby()` | `MeshNetworkManager.swift:360` | Same |
| `joinMesh(_:)` | `MeshNetworkManager.swift:386` | Same; the only consumer of `LobbyMeshSummary` |
| `lobbyMeshes` / `lobbyIndividuals` state | `:157`, `:158` | Read only by `MeshLobbyView` |
| `LobbyMeshSummary`, `LobbyIndividual` | `MeshNetworkManager.swift` | Dead once the above go |
| Lobby-array population | `handlePeerDiscovered` `:877–898` | Builds the (now-unread) browse arrays |
| Trainer-client invite branch | `handlePeerDiscovered` `:870–875` | `role` always `nil` |
| `handlePeerLost` lobby maintenance | `:911–918` | Only maintains the dead arrays |

**In `handlePeerDiscovered`, keep the `isProximityJoin` branch (`:855–867`).** That branch already performs the auto-invite for the live flow.

**[lower-confidence]** The open-mesh auto-invite at `:900–908` sits *after* the `isProximityJoin` early-return, so it's unreachable while `isProximityJoin` is the only search mode. It is safe to remove *only if* you confirm no non-proximity search path will be restored. If unsure, leave `:900–908` in place — it's harmless dead code, not a correctness risk.

Minor follow-on: `currentDiscoveryInfo()` still advertises `meshID/meshName/memberCount` (`:838–842`) that only the dead browse path read. Harmless, but can be trimmed in the same pass.

### 2.5 Workshop / texture subsystem — UI removed, data layer retained

You removed the Workshop page, but unlike **Hobbies** (which is fully gone — *zero* remnants found, good), the Workshop *data model and persistence are entirely intact and orphaned*:

- `WorkshopData` (`Models.swift:2357`), `TextureEntry` (`:2367`), `TextureTag` (`:2375`).
- `FernletStore.workshop` is decoded, re-encoded into every snapshot, and reset on wipe (`FernletStore.swift:15, 100, 137, 912, 959`).
- `FernletStore.addTexture(_:tags:)` (`:873`) is the **only writer and it has no caller** — an orphaned mutation method.
- **No view references texture/workshop at all.**

So this is a dead feature that still costs serialization work on every save and carries a stale blob (`fernlet-workshop`) for existing users.

> **Migration caveat:** `workshop` is a property of the `Codable` `FernletSnapshot` / `LocalFernletDatabase`. The decoders already use `decodeIfPresent(...) ?? WorkshopData()` (`LocalFernletRepository.swift:136`, `:151`), so *dropping the property is backward-compatible on read* — old blobs are simply ignored. This makes removal low-risk, but it is still a deliberate data decision (existing CloudKit/on-disk `fernlet-workshop` data becomes unreadable). Decide explicitly before removing.

### 2.6 Isolated dead views/enums (zero-risk quick wins)

Each of these appears only at its declaration:

| Symbol | Location |
|---|---|
| `CompactSignalRow` | `HomeView.swift:513` |
| `MicronutrientSummaryView` | `FoodView.swift:207` |
| `NutritionLabelScanReviewView` | `FoodView.swift:798` |
| `RecipeSearch` (enum) | `FoodDataCatalog.swift:382` *(the live twin is `FoodItemSearch`)* |
| `OnboardingView` (struct) | `OnboardingView.swift:3` *(the live entry is `OnboardingCoordinator`)* |
| `NutritionPreviewCard` | `OnboardingView.swift:126` *(used only by the dead `OnboardingView`)* |

**Keep `ProfileEditor` (`OnboardingView.swift:59`)** — it's used by `SettingsSheet`. So `OnboardingView.swift` stays as a file; only the two dead structs come out.

---

## 3. Functionality NOT carried over (the carryover gaps)

These are **not** dead code to delete — they are capabilities the old lobby provided whose backing logic still exists but now has no UI, or which the plan said to preserve and didn't get re-wired. This is the part of your question about "functionality that wasn't brought over."

### 3.1 `addPhoto` reuse — **CRITICAL, verify first** [verify in DisposableCameraView]

The plan (line 145) is explicit: the camera should feed captures *straight into the existing* `MeshNetworkManager.addPhoto(_:)` (`:491`), because that method is where the **per-sender per-session quota, group-key encryption, local caching, and broadcast to active slots all live**. The camera was meant to "just replace `PhotosPicker` as the input."

In this snapshot, `addPhoto` has **no caller** (the only one was `MeshLobbyView`'s `PhotosPicker`). Either:
- the camera calls `addPhoto` and it's wired in `DisposableCameraView` (not in snapshot) — fine; or
- the camera implements its own capture→broadcast path — in which case **the quota and the group-key encryption are silently bypassed**, which is a privacy/correctness regression given Fernlet's encrypt-at-rest-and-in-transit posture.

**Action:** open `DisposableCameraView` and confirm the capture path terminates in `addPhoto(_:)` (or otherwise reuses `resizedForFriendSharing()` + the quota counter `photosAddedThisSession` + group-key sealing). If not, route it through `addPhoto`. Keep `addPhoto`.

### 3.2 Closed-mesh admission approval + token rejoin prompt — gap

The admission machinery still runs: `pendingAdmissionRequests` is populated on inbound requests (`MeshNetworkManager.swift:1278–1279`, plus the UI-test path at `:1919`), and `allowAdmission`/`declineAdmission` (`:546`/`:595`) exist. But the *only* surface that displayed them was the dead `MeshLobbyView`. So today an admission request can queue with no way to allow or decline it.

Per plan B‑DEC‑3 (lines 122, 128), dropping the prompt for *proximity* joins is intentional (touch = consent). **But the plan says to keep the prompt for the token-based silent rejoin path** — and that wiring was never added. `MeshAdmissionPromptSheet` is the orphaned sheet that should host it.

**Action:** re-wire `MeshAdmissionPromptSheet` into the rejoin flow (present it when a `MeshAdmissionToken` rejoin request arrives), or, if you've decided rejoin no longer needs confirmation, explicitly remove `MeshAdmissionPromptSheet` + `allowAdmission`/`declineAdmission` + the `pendingAdmissionRequests` consumer together. Right now it's in limbo.

### 3.3 A user can no longer close their own mesh — gap / design decision [verify in DisposableCameraView]

`setSessionOpen(_:)` (`MeshNetworkManager.swift:479`) has **zero callers**, and `setMeshMode(_:)` (`:467`) is reachable only through it. The old lobby exposed an Open/Closed `Picker` (`MeshLobbyView.swift:256–267`). Consequence:

- A user can't set their mesh to `.closed` from the UI.
- The closed-only group-key encryption branches (`:1457`, `:1475`) are therefore **locally unreachable** (they can still trigger from a *remote* peer's closed descriptor via `:1163`, but never from this device's own choice).

**Action:** decide intent. If "touch = consent + post-hoc block" fully replaces closed mode (consistent with the plan's direction), then also prune the closed-mode encryption branches so the code matches reality. If a deliberate "lock this mesh" control is still wanted, surface it behind the camera's info affordance. Check whether `DisposableCameraView`'s info affordance already calls `setSessionOpen` before treating it as dead.

### 3.4 `meshError` is never shown to the user — gap

`meshError` (`:164`) is still assigned — notably the photo-quota message inside `addPhoto` (`:498`) and the **key-rotation exclusion** message "You were excluded from the key rotation. Rejoining…" (`:1795`). The only consumer was `MeshLobbyView`'s `.alert` (`:41–48`). So these user-facing errors now go nowhere — including a live security-relevant path (rotation exclusion).

**Action:** surface `meshError` in `ConnectView`/`DisposableCameraView` (an alert or toast), or replace it with whatever error channel the new flow uses. Don't leave assignments that no one reads.

### 3.5 Member-removal vote (propose / second) — gap [verify in DisposableCameraView]

`proposeRemoval(of:)` (`:405`) has **no caller** in the snapshot; `pendingRemovalProposals` is populated on inbound (`:1225`) but **no view consumes it**; `secondRemoval`/`canSecondRemoval` (`:431`/`:424`) are only self-referenced. This is the two-person "vote to remove a member" flow. It may be intended for the camera's roster/info affordance.

**Action:** if `DisposableCameraView` surfaces a participant roster, wire `proposeRemoval`/`secondRemoval` + display `pendingRemovalProposals` there. If not, this whole sub-flow is orphaned and should be either built or removed as a unit.

### 3.6 Block-from-roster (minor)

The old lobby let you block a peer directly from the member roster (`MeshLobbyView.swift:359–361` → `store.blockProximityPeer`). Blocking itself is **not lost** — it remains in Manage Friends (`FriendListView.swift:110`). The only thing gone is the in-session shortcut. Decide whether session-time blocking is worth restoring in the camera roster; otherwise no action.

### 3.7 Mesh rename (minor)

`renameMesh(_:)` (`:457`) has no caller (was `MeshLobbyView`'s rename sheet). The plan tucks the mesh name behind an "info" affordance but doesn't preserve a rename control. Likely safe to drop; if you want rename, add it to the info affordance. Otherwise remove `renameMesh` + the rename sheet remnants.

---

## 4. Verify-against-`DisposableCameraView` checklist

Because that file isn't in the snapshot, confirm each before acting:

- [ ] **§3.1** Camera capture routes through `addPhoto(_:)` (quota + group-key encryption intact). *Highest priority.*
- [ ] **§3.3** Does the info affordance call `setSessionOpen`/`setMeshMode`? (close-mesh control)
- [ ] **§3.5** Does the roster call `proposeRemoval`/`secondRemoval` and show `pendingRemovalProposals`?
- [ ] **§3.4** Is `meshError` surfaced anywhere in the camera/connect UI?
- [ ] Confirm `DisposableCameraView` exists in the repo (it's referenced at `ConnectView.swift:22`) — it simply wasn't included here.

---

## 5. Suggested removal order (keeps the build green)

1. **§2.6 isolated dead views/enums** — zero dependencies, immediate.
2. **§2.1 `MeshLobbyView.swift`** — delete file. *Keep `MeshAdmissionPromptSheet.swift`* (tracked under §3.2).
3. **§2.2 old photo-share cluster** — remove the three dead types; keep the rest of the file; rename the file if desired.
4. **Resolve §3 gaps** (especially §3.1) — re-wire what should be carried over *before* deleting the manager API that backs it, so you don't remove something the camera was supposed to call.
5. **§2.3 trainer feature** — after confirming it's shelved; keep the audit/trust infra; optional rename.
6. **§2.4 lobby-browse manager API** — after confirming no non-proximity search path remains.
7. **§2.5 Workshop/texture** — last; make the serialization-migration decision explicit.

---

## Appendix — how "dead" was determined

For every top-level `struct`/`class`/`enum`/`protocol`/`actor`, the number of whole-word occurrences of its name across all `.swift` files was counted. A count of exactly **1** (the declaration itself) means it is referenced nowhere — including its own file and any `#Preview` — and is the strongest dead signal. Counts of 2+ were traced by hand to distinguish "used internally / in one external file" from "referenced only inside other dead code" (the cascade cases: `MeshAdmissionPromptSheet`, `FriendPhotoSharingService`, `TrainerDisclosureCardModel`, `NutritionPreviewCard`, `LobbyMeshSummary`). Manager *methods* (not caught by the type pass) were traced individually via call-site grep, which is how the orphaned-but-live-state items in §3 surfaced.
