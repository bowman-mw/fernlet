# Life Tab Redesign — Implementation Plan

**Status:** New. Author: planning pass over the current Fernlet codebase.
**Audience:** the engineer(s) implementing this. Read §0 before touching anything.
**Scope:** three related workstreams on the **Life** tab (`FernletTab.social`, hosted by `SocialHubView`):

- **A — Information architecture.** Remove the **Workshop** and **Hobbies** sections; collapse **Friends** + **Meshes** into one **Connect** surface.
- **B — Proximity-join model.** Replace lobby browsing with a single **Join** action gated on **15 cm** proximity; automatically pick pairwise vs. mesh; promote pairwise → mesh when a second person joins.
- **C — Disposable-camera session UI.** When connected (pairwise or mesh), the screen becomes a toy disposable camera: small viewfinder, no controls, a "film" counter, and a manual **wind** gesture between shots that prevents accidental photos.

Workstream A is independent and should ship first. B and C are coupled and ship together.

This builds on the existing mesh stack and does **not** require new cryptography or transport. Reuse, don't rebuild.

---

## 0. The one constraint that drives everything: 15 cm is a *post-connection* gate, not a discovery filter

The implementer must internalize this before designing the join flow, because it inverts the naïve reading of the request.

**Distance is not available at discovery time.**

1. Peer discovery happens over **MultipeerConnectivity** (`MCNearbyServiceBrowser` inside `MeshMultipeerSession`). It finds devices over Bluetooth / Wi-Fi at **tens of meters** and exposes **no distance**.
2. Precise distance comes only from **NearbyInteraction** (`NIRangingSession`, UWB). NI can start **only after** an MC channel exists and the two devices have exchanged NI discovery tokens.
3. So "look for devices within 15 cm" must be implemented as: discover over MC as usual, *silently* stand up ephemeral channels, run ranging, and only **commit** (and only surface) a peer once it has stayed within **15 cm** for a short dwell. Devices that never come close are never committed and never shown. To the user this *looks like* "it only finds things within 15 cm."

This is the same shape as the existing "bump to confirm" mechanism. Today `TapConfirmedDetector` (in `NIRangingSession.swift`) requires the peer to sit **< 5 cm for 1 s** before a session is confirmed (`proximityThreshold = 0.05`, `dwellSeconds = 1.0`, `minimumSamples = 3`). The redesign reuses this detector at **0.15 m** and makes it the gate that decides whether a discovered peer is committed at all.

### 0.1 A handshake-ordering problem you must fix (subtle, important)

Trace the current `ProximityCoordinator` handshake:

```
MC channel connects
  → state .awaitingTapConfirmation
  → finishTapConfirmation()           // gated behind tap/dwell
  → sendIdentityIntroduction()        // <-- NI discovery token is sent HERE (makeIdentityRangingPayload)
  → peer replies, handleIdentityEnvelope()
  → startRangingIfPossible()          // <-- ranging actually STARTS here
  → distance begins flowing
```

`sendIdentityIntroduction` is only ever called from `finishTapConfirmation`, and ranging only starts in `startRangingIfPossible` (reached *after* identity introduction). **Therefore distance is only available after confirmation has already happened.** You cannot gate confirmation on distance with the current ordering — it is circular.

**Required change for workstream B:** reorder the handshake so NI discovery tokens are exchanged **immediately on channel-ready**, ranging starts before any confirmation, and the **15 cm dwell then drives `finishTapConfirmation` automatically**. Concretely: move the token exchange out from behind the tap gate (e.g., send an `identityIntroduction`/token exchange as soon as the channel connects), keep identity *verification* where it is, but let the proximity dwell — not a manual tap — be what advances the state machine. This is the central coordinator edit; everything else in B is orchestration on top of it.

### 0.2 Hardware caveat that must be designed for, not ignored

Precise ranging requires a U1/U2 chip (iPhone 11 and later; the 2020/2022 SE models do **not** qualify). `NIRangingSession.isHardwareSupported` already gates this and emits `RangingState.fallback(rssiOnly:)` when unsupported. On those devices **there is no 15 cm measurement.** The plan must choose a fallback (see B‑DEC‑1) rather than silently failing to connect.

---

## A. Information architecture: one combined Connect surface

### A1. Collapse `SocialHubView`
File: `SocialHubView.swift`. Today `SocialHubSection` = `.workshop, .friends, .mesh, .hobbies`, rendered as a paged `TabView` under a `HubSectionPicker`.

- **Recommended:** delete the section enum + picker entirely. `SocialHubView` becomes a thin wrapper hosting the new `ConnectView` directly (one section ⇒ no picker chrome).
- Alternative: keep `SocialHubSection` with a single `.connect` case if you want the picker for future growth. Adds dead chrome today; not recommended.
- Either way, the `.workshop` and `.hobbies` tags and their child views (`WorkshopView`, `PersonalScreenView(screen: .hobbyNotes…)`) leave this file.

### A2. New `ConnectView.swift` (replaces `MeshLobbyView` + `FriendListView` as hub content)
This is a **view-composition** change, not a logic rewrite. Top-level states:

- **Idle (no session):** the single **Join** button (workstream B) on top, the **friends roster** below. Reuse the existing `FriendListView` body as a subsection — its trusted-peer list, All/Friends/Blocked filter, swipe block/unblock/remove, and expandable detail card are all fine as-is. Do not change `store.trustedProximityPeers` or the block APIs.
- **Searching:** "hold your phones together" guidance + live distance readout (workstream B).
- **In a session (pairwise or mesh):** the disposable camera (workstream C).

### A3. Remove Workshop + Hobbies and fix every call site
These references are scattered; here is the grounded list so nothing dangles:

- `SocialHubView.swift` — remove `.workshop` / `.hobbies` tags (A1).
- `ContentView.swift`
  - `@State private var socialHubSection: SocialHubSection = .workshop` (line ~21) → default to the surviving case, or delete the state if A1 removes the enum.
  - `PersonalScreenView` switches (~371–474) contain `.workshop` and `.hobbyNotes` arms (title, icon, body, primary action). Delete these arms **iff** the `PersonalScreen` cases are removed (see A‑DEC‑1/2).
- `HomeView.swift`
  - `socialHubSection` binding (line 9) — update/remove with the enum.
  - Quick-log routing (~320–329): `.friends` currently sets `socialHubSection = .friends` → repoint to the combined Connect section; `.photos` and `.hobbyNotes` set `socialHubSection = .hobbies` → these break when `.hobbies` is gone (A‑DEC‑3).
  - `isActive` (~243–269) and `titleText` (~225–240) arms reference the `.hobbyNotes` / `.photos` / `.friends` shortcuts.
- `Models.swift`
  - `PersonalScreen` enum (~158–209): `.workshop`, `.hobbyNotes` (and `.photos`, `.friends`).
  - `FernletShortcut` enum (~288): `.hobbyNotes` / `.photos` cases consumed by Home quick-log.
  - `WorkshopData` (~2371), `TextureEntry` (~2381).
- Persistence/store: `workshop` participates in snapshot Codable round-trips — `FernletStore.swift` (99, 135, 952), `LocalFernletRepository.swift` (67, 86, 136, 181, 305, 365), `CoreDataFernletRepository.swift` (223). **Do not naïvely delete** (see A‑DEC‑2).
- `WorkshopView.swift` — delete the file once unreferenced.
- The `.texture` input sheet (`FernletSheet.texture`, its case in `ContentView.sheetContent`, the editor in `SharedSheets.swift`, and `WorkshopTab`) — only used by Workshop; remove if Workshop data is excised.
- Tests: UI tests touching Workshop/Hobbies; `FernletSnapshotRoundTripTests` (asserts on `workshop`).

### A — open decisions (with recommended defaults)
- **A‑DEC‑1 — Is Workshop a real feature?** It surfaces `texture / handoff / Claude notes` "design observations" — reads like internal dev tooling, not a user feature. *Recommended:* remove it as a user surface. Confirm it isn't intentionally shipped.
- **A‑DEC‑2 — Model fate.** Removing the *page* ≠ removing the *model*. Safest: remove views/navigation now but **keep `WorkshopData` in the snapshot schema** (`decodeIfPresent`, default empty — `LocalFernletRepository` already does this at line 136) so existing on-device and iCloud snapshots still deserialize. Fully deleting the Codable type is a **breaking snapshot migration**, not a delete — schedule separately if truly wanted.
- **A‑DEC‑3 — Orphan Home shortcuts.** `FernletShortcut.photos` is a TODO stub; `.hobbyNotes` points at the removed page. *Recommended:* drop both from the quick-log/`homeWidgets` set; keep `.friends`, repointed to Connect.

---

## B. Proximity-join + automatic pairwise/mesh

### B1. The behavior, stated precisely
1. User taps **Join**. The app advertises + browses `fernlet-friend`, begins exchanging NI tokens and ranging with every peer that connects (per §0.1), and **surfaces nothing yet**.
2. A peer that stays within **15 cm** for the dwell becomes **committed**.
3. **Exactly one** committed peer, nothing else pending → **pairwise** session (no `MeshDescriptor`; just the two of you).
4. **Two or more** committed peers (committed in the same window, or a second arrives later) → **materialize a mesh**: lazily create a `MeshDescriptor` (silly name from `MeshNameGenerator`), broadcast it, admit the committed peers, keep accepting further 15 cm commits up to the roster cap.
5. "One, then someone else joins" is just rule 4 fired by the *second* commit: when a pairwise session is live and a new peer crosses 15 cm (or the existing peer's device gets a third joiner), **promote pairwise → mesh in place** without dropping the first peer.

### B2. Where the logic lives
- **Session-shape decision → `MeshNetworkManager`.** It already owns the slot table (`maxActiveSlots = 3`, `maxLightweightSlots = 2`) and runs one `ProximityCoordinator` per peer. Today it has no pairwise/mesh distinction — it only creates a `MeshDescriptor` when `startNewMesh` is called. Formalize:
  - Derive shape: `currentMesh == nil` + exactly one committed slot ⇒ **pairwise**; ≥ 2 committed ⇒ create `currentMesh`, broadcast, run the existing admission/descriptor gossip. (You can model this as a computed `sessionShape` or an explicit enum; computed is fine.)
  - Promotion = "on the 2nd commit, if `currentMesh == nil`, call the existing mesh-creation path and admit the already-committed peer + the new one." The existing `allowAdmission` / `broadcastMeshDescriptor` / group-key wrapping all still apply.
- **15 cm gate → `ProximityCoordinator` + `NIRangingSession`.**
  - Generalize `TapConfirmedDetector` to take a configurable `proximityThreshold` (today hard-coded `0.05`); inject `0.15`. Keep the dwell/sample logic. Rename to reflect "proximity commit," not "tap."
  - Apply the §0.1 reordering so distance flows *before* commit.
  - Add a coordinator → manager signal such as `onProximityCommitted(peer)`. `MeshNetworkManager` listens to **that** (not "channel ready") to count commits and drive the shape decision. `handleChannelReady` should stand up the coordinator and start ranging, but a slot is only "in the session" once committed.
- **Tear down uncommitted channels.** In a crowded room you'll open many half-connections. Add a **pending-commit TTL** (recommended 20–30 s): an uncommitted slot is dropped via `removeSlot` when it expires.

### B3. Replace the lobby UI
- Delete the browse-list rendering in `MeshLobbyView` (`lobbyMeshes` / `lobbyIndividuals` lists). The user no longer picks a mesh from a list — proximity decides. Keep those arrays internally only if useful for diagnostics; they must not drive the primary UI.
- Collapse the **"Start new mesh"** + **"Find friends"** split (`mesh.lobby.start` / `mesh.lobby.findFriends`) into one **Join** button. There is no separate "create" — a mesh appears automatically on the 2nd commit.
- Searching state: guidance ("hold the backs of your phones together") + a live distance readout. Reuse the existing cm formatter pattern in `FriendPhotoShareView.proximityDistanceText`. A ring that fills as distance approaches 15 cm is a nice touch.

### B4. Open-mesh / admission interplay
- The existing open-mesh auto-invite (`handlePeerDiscovered`, `shouldAcceptInvitation`) and admission request/grant flow can remain as the **transport** mechanism, but the **gate to actually admit becomes 15 cm proximity**, not a lobby tap. Physical touch is itself a strong consent signal.
- `MeshAdmissionPromptSheet` likely becomes unnecessary for proximity-initiated joins; keep it only for the (now-rare) token-based silent **rejoin** path (the 1–2 hour `MeshAdmissionToken` window).
- Block-list enforcement stays where it is (`shouldAcceptInvitation` checks `store.isBlockedFingerprint`; inbound photo filtering already checks blocked senders).

### B — open decisions
- **B‑DEC‑1 — No-UWB fallback.** On devices without precise ranging there is no 15 cm measurement. *Recommended:* show an explicit on-screen **"We're touching — connect"** manual confirm on both devices (functionally the legacy tap-to-confirm), clearly labeled as a fallback. Alternatives: block mesh on unsupported hardware, or an RSSI "very close" heuristic (unreliable for a 15 cm claim — avoid).
- **B‑DEC‑2 — Threshold / dwell tuning.** Recommended `threshold = 0.15 m`, `dwell = 0.8 s`, `minimumSamples = 3`, and require the peer to **stay** under 15 cm for the dwell (not just touch once) to avoid accidental passes. Confirm.
- **B‑DEC‑3 — Admission prompt for proximity joins.** *Recommended:* drop the "Allow this person?" sheet for proximity-confirmed joins (touch = consent); rely on post-hoc block. Keep the prompt only for token rejoin.
- **B‑DEC‑4 — Which 1:1 code path?** Two exist: the standalone `FriendPhotoSharingService` (its own coordinator) and the `MeshNetworkManager` slot table. Pairwise → mesh promotion is dramatically simpler if **everything runs through `MeshNetworkManager`** and pairwise = "1 committed slot, no descriptor." *Recommended:* route pairwise through `MeshNetworkManager`; treat `FriendPhotoSharingService` as deprecated for this surface (delete once Connect stops using it).
- **B‑DEC‑5 — Auto-friend on commit?** When two strangers touch phones, do they auto-add to `trustedProximityPeers`, or only on a later "keep" step? *Recommended:* commit creates a **session** peer; offer friendship (don't force it) at leave time, keeping the friends list intentional. Note: `handleIdentityEnvelope` already auto-confirms *already-trusted* peers; decide whether proximity should also auto-confirm strangers (it probably should, given B‑DEC‑3).

---

## C. Disposable-camera session UI

### C1. Concept → concrete state
| Requirement | Mechanic |
| --- | --- |
| "Small view of the camera" | Live `AVCaptureSession` preview rendered as a **small viewfinder window** inside camera-body chrome (the body fills the screen, the preview is a small window). `UIViewRepresentable` wrapping `AVCaptureVideoPreviewLayer`. New file `DisposableCameraView.swift` + a small `CameraCaptureController` (`@Observable`) around `AVCaptureSession`. |
| "No camera controls" | One shutter button. No flash / zoom / flip / exposure UI. Fixed back camera, auto everything. |
| "'Film' countdown" | Visible **exposures-remaining** counter. Tie to a per-session film budget. `MeshNetworkManager.maxPhotosPerSenderPerSession` is currently `10` — repurpose as the film count (recommend 24 or 27 — see C‑DEC‑1). At 0, the shutter locks ("film used up"). |
| "Manual winding / no accidental photos" | An `isArmed` gate. Shutter is **disabled unless `isArmed`**. Taking a photo sets `isArmed = false` and decrements the counter. The user must perform a **wind gesture** (a `DragGesture` across a thumbwheel/lever past a threshold, with `UIImpactFeedbackGenerator` detents) to set `isArmed = true` again. This both creates the tactile winding feel and structurally prevents double-fire / accidental taps. |

### C2. Capture feeds the existing pipeline — do not build a parallel sender
A captured frame → JPEG `Data` → straight into the **existing** `MeshNetworkManager.addPhoto(_:)`. That method already: normalizes via `resizedForFriendSharing()`, enforces the per-session quota, encrypts under the group key if one exists, caches locally, and broadcasts to active slots. The camera simply replaces `PhotosPicker` as the input. Reuse `.resizedForFriendSharing()` and the quota machinery unchanged.

### C3. "You don't see the photos until they're developed"
Disposable-camera realism implies the shared photos are **not** shown as a live grid during the session. The app already has the right flow: "review on disconnect → save selected to Photos / discard the rest" (`FriendPhotoReviewSheet`, `beginReviewOrDisconnect`, `FriendPhotoLibrarySaver`). That **is** "develop the film when you leave." Rework the in-session screen to hide the live grid and reveal the roll only at leave/develop time. (This is a real fork with today's live grid — see C‑DEC‑2.)

### C4. Where it renders
`ConnectView`'s in-session state hosts `DisposableCameraView` for **both** pairwise and mesh — identical UI; only the recipient count differs underneath. The mesh name / member roster lives behind a small "info" affordance so the camera body stays uncluttered. This replaces the photo section + `PhotosPicker` in `MeshLobbyView.meshDetailView`.

### C — open decisions
- **C‑DEC‑1 — Film count & scope.** Exposures per session — recommend **27 per person** (matches a real disposable; current quota is per-sender). Confirm number and per-person vs. shared-roll.
- **C‑DEC‑2 — Live grid vs. hidden-until-developed.** *Recommended:* hidden during session, revealed on leave/develop (reuses the review sheet). Confirm — keeping a live grid weakens the metaphor.
- **C‑DEC‑3 — Library import.** *Recommended:* remove `PhotosPicker` from this surface (camera-only is the point). If kept, hide it behind a deliberate tap.
- **C‑DEC‑4 — Wind gesture form.** Thumbwheel drag vs. lever swipe vs. crank. *Recommended:* right-side thumbwheel `DragGesture` with haptic detents. Confirm aesthetic.
- **C‑DEC‑5 — Permissions.** `NSCameraUsageDescription` already exists (journal capture); confirm present and reword to cover in-person sharing.

---

## Acceptance criteria

**A.** Life tab shows one combined Connect surface; no Workshop/Hobbies tabs anywhere; app builds with zero references to removed cases; existing on-device/iCloud snapshots still load; friend management (block / unblock / remove / filter) still works unchanged.

**B.** With two UWB phones, tapping **Join** on both and touching them connects **pairwise** within the dwell; bringing a third within 15 cm **promotes to a mesh** with all three; phones never brought within 15 cm never connect or appear; uncommitted channels are torn down after the TTL; non-UWB devices get the documented fallback (B‑DEC‑1).

**C.** In-session screen shows a small live viewfinder, exactly one shutter, a decrementing film counter, and a wind gesture that must be performed between shots; the shutter is inert until wound and when film is 0; captured photos route through `addPhoto` / group encryption **unchanged**; leaving triggers develop / review / save.

---

## Test & documentation impact
- **Update:** `MeshNetworkManagerTests` (pairwise vs. mesh shape, promotion on 2nd commit, commit TTL), `ProximityCoordinatorTests` + `NearbyRangingSessionTests` / `MockRangingProvider` (15 cm dwell commit + reordered handshake), `MeshNetworkUITests` (new Join flow; removed `mesh.lobby.*` selectors), `FernletSnapshotRoundTripTests` (Workshop retention per A‑DEC‑2).
- **New:** a pure unit test of the disposable-camera state machine (arm / disarm / wind / film-count) as an `@Observable` controller, independent of AVFoundation.
- **Docs:** update `MeshNetworkImplementationPlan.md` §6.5 (creation/join/leave) and §11 (UI specs) to describe proximity-join + the disposable camera; update the social section of `FernletSpecificationV3.md`; refresh `FileIndex.md` (add `ConnectView.swift`, `DisposableCameraView.swift`; remove `WorkshopView.swift`, and `MeshLobbyView.swift` / `FriendListView.swift` as they are absorbed).

## Suggested sequencing
1. **A** — IA cleanup (independent; yields a clean Connect shell).
2. **B** — proximity-join: the §0.1 handshake reorder + 15 cm commit gate in `ProximityCoordinator`, then pairwise/mesh shape + promotion in `MeshNetworkManager`, behind the Connect shell.
3. **C** — disposable camera feeding the existing `addPhoto` pipeline.

Ship A first; B and C together.

---

## Appendix — ready-to-paste implementation prompt

> Implement the Life-tab redesign in the Fernlet iOS app across three workstreams. **Read the handshake-ordering note first:** 15 cm is a post-connection commit gate, not a discovery filter — MultipeerConnectivity discovers at radio range with no distance, and NearbyInteraction (UWB) only ranges after channels exist and tokens are exchanged. The current `ProximityCoordinator` only starts ranging *after* tap-confirmation (`finishTapConfirmation → sendIdentityIntroduction → startRangingIfPossible`), which is circular for distance-gated auto-connect; reorder so NI tokens exchange on channel-ready, ranging starts before commit, and a 15 cm dwell (generalize `TapConfirmedDetector` from the hard-coded 0.05 m to 0.15 m, keep the dwell) drives commit automatically.
>
> **A (IA):** In `SocialHubView`, remove the Workshop and Hobbies sections and collapse Friends + Meshes into one new `ConnectView`. Fix all call sites: `ContentView` (`socialHubSection` default, `PersonalScreenView` `.workshop`/`.hobbyNotes` arms), `HomeView` (`socialHubSection` binding + quick-log routing for `.friends`/`.photos`/`.hobbyNotes`), `Models.swift` (`PersonalScreen`, `FernletShortcut`, `WorkshopData`/`TextureEntry`). Keep `WorkshopData` in the snapshot Codable schema (decode-if-present, default empty) so existing snapshots still load — do not break round-tripping. Delete `WorkshopView.swift` and the `.texture` sheet once unreferenced. Reuse the existing `FriendListView` body as the friends section inside `ConnectView`.
>
> **B (proximity-join):** One **Join** button (no separate "create mesh"/"find friends"). On Join, silently establish channels + ranging with all in-range peers; commit a peer only after it stays < 15 cm for ~0.8 s. One committed peer ⇒ pairwise (no `MeshDescriptor`); ≥ 2 ⇒ lazily create + broadcast a `MeshDescriptor` and admit them via the existing admission/descriptor flow; promote pairwise → mesh in place on the 2nd commit without dropping the first peer. Route everything through `MeshNetworkManager` (deprecate the standalone `FriendPhotoSharingService` for this surface). Add an `onProximityCommitted` coordinator signal that drives the shape decision, and a 20–30 s TTL that tears down uncommitted channels. Drop the lobby browse list and the admission prompt for proximity joins (keep it only for token rejoin). For non-UWB hardware (`isHardwareSupported == false`), fall back to an explicit on-screen "we're touching — connect" confirm on both devices.
>
> **C (disposable camera):** When in a session (pairwise or mesh), `ConnectView` shows a `DisposableCameraView`: a small live `AVCaptureSession` viewfinder inside camera-body chrome, no flash/zoom/flip/exposure controls, one shutter, a visible film counter (repurpose `maxPhotosPerSenderPerSession`; set to 27), and a wind gesture (right-side thumbwheel `DragGesture` with haptic detents) that re-arms the shutter between shots. The shutter is inert unless armed and when film is 0. Each capture → JPEG `Data` → existing `MeshNetworkManager.addPhoto(_:)` (no parallel sender). Hide the shared photos during the session; reveal the roll only on leave via the existing review/develop flow (`FriendPhotoReviewSheet` → save to Photos / discard). Confirm `NSCameraUsageDescription` covers in-person sharing.
>
> Update the affected unit/UI tests and the docs (`MeshNetworkImplementationPlan.md`, `FernletSpecificationV3.md`, `FileIndex.md`). Where a decision is marked `*-DEC-*` in the plan, use the recommended default unless told otherwise.
