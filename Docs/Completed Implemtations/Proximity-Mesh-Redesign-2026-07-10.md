> **CLOSED 2026-07-19 — SHIPPED.** All 5 phases verified on `main` (payload registry, keep-friends prompt, MeshClothingShop, PresenceManager + `_fernlet-near`, SessionMessageStore/chat). Residuals carried to the tracker: `MeshAdmissionPromptSheet` has no call site (admission requests never surface), and the Phase-3b recipe-cap sender UX needs a targeted check. Live tracker: [RemainingWork-2026-07-19.md](../RemainingWork-2026-07-19.md).

# Proximity Mesh Redesign — Plan & Tracker (2026-07-10)

Consolidates the proximity subsystem from four per-feature Multipeer radios into two standing
radios plus on-demand pairwise connections. Grounded in a full-subsystem investigation
(6 specialist deep-reads + 4-lens adversarial design critique, 2026-07-10); every load-bearing
fact below was verified against source.

## Owner decisions (2026-07-10)

| Topic | Decision |
| --- | --- |
| Shop + temp messages | Collapse onto the friend mesh (`fernlet-friend`). |
| Shop access model | **No in-session shop UI.** Catalogs exchange during the live session; the shop OPENS after the session ends and stays open **1 hour** (memory-only; closes early on app quit or when a new session starts). |
| Temp messages scope | Live-session only; messages **vanish at session end**. Nothing retained, nothing synced. |
| Recipe sharing | Hard cap at exactly 2 devices — radio "closes" (stops advertising + browsing) once connected, reopens on teardown. |
| Hearts | Sendable to a nearby friend without a full mesh, via the presence layer + on-demand short-lived pairwise connection. **Consume on send. No daily limit for in-person hearts; rate limit 1 heart per 5 minutes** (interpreted per-friend, receive side mirrors it — confirm if global was intended). Future remote/dead-drop hearts (Phase-6 roadmap) may reintroduce limits. |
| Friend minting | **One-sided** (each user independently keeps the other as a friend). Consequence: pairwise-DH presence tags make presence recognition mutual-by-construction — a one-sided friend never appears "nearby". Accepted. |
| Presence default | **Off**, with a one-time enable prompt when the user keeps their first friend. Runs on Home/Food/Move/Social, foreground + unlocked only. |
| Payload architecture | **Modular payloads are a first-class requirement**: app updates that add payload kinds must never break older clients joining a mesh. Unknown types are verified-then-parked; capabilities advertised in the handshake; MeshNetworkManager dispatch becomes a handler registry. |
| Device floor | iPhone 11+ (all UWB) — no manual-commit path needed; the 15 cm dwell stays the only session-commit ritual. |

## Target end-state

1. **Friend mesh** (`fernlet-friend`, `MeshNetworkManager`) — the one social container: photos +
   shop catalogs + temp messages. Formation ritual unchanged (UWB dwell, admission for 3rd+).
2. **Presence radio** (NEW, service type must be ≤15 chars — use `fernlet-near`; `fernlet-presence`
   is 16 chars and crashes MCNearbyServiceAdvertiser at init) — standing advertise+browse while
   eligible; broadcasts rotating pairwise-DH tags only (no display name, no stable sid); forms no
   automatic connections. Feeds: nearby-friends set, hearts delivery, quicker session formation UX.
3. **Recipe pairwise** (`fernlet-recipe`) — own radio, hard 2-device cap.
4. **Deleted:** the standalone `fernlet-heart` and `fernlet-clothes` radios.

## Latent bugs this plan absorbs (all verified 2026-07-10)

- **Bonjour wall:** `Info.plist` `NSBonjourServices` declares only `_fernlet-coach/_fernlet-friend/_fernlet-recipe`.
  Browsing `fernlet-heart`/`fernlet-clothes` fails on device (iOS 14+ local-network privacy) and both
  failure delegates are empty (`MeshMultipeerSession.swift:304,333`) → silent. Hearts + shop discovery
  is transport-dead on real devices today. (Simulator under-enforces; that's why tests pass.)
- **Shop never connects:** `ProximityClothingShareManager` has zero `session.invite` call sites — both
  sides advertise/browse/accept but nobody invites.
- **Friend vault is orphaned:** `ProximityTrustVault.trust()` has zero production callers
  (`FernletStore.trustProximityPeer` — tests only; historical writers FriendPhotoShareView +
  TrainerProximityService were deleted). Hearts gate send AND receive on vault friendship → hearts are
  end-to-end non-functional; FriendListView can only show block stubs.
- **Recipe go-dark:** after a share the sheet's `onDisappear → stop()` kills the radio and nothing
  restarts passive listening until the next tab/scene/lock event (`ContentView.swift:613-633`).
- **Wire-brick hazard:** unknown `PayloadType` rawValue throws in envelope decode; the coordinator's
  catch calls `fail()` → slot eviction (`ProximityCoordinator.swift:583-633`). Any new payload kind
  bricks old clients — Phase 1 removes this class.

## Key architecture facts (for implementers)

- All four radios share: keychain identity (Ed25519 + X25519, `ThisDeviceOnly`, never rotated),
  per-peer `ProximityCoordinator` handshake (friend mode, exactly 1 concurrent RTT: signed
  identityIntroduction ⇄ identityAcknowledge, then commit gate), per-connection
  `FriendSessionTrustPolicy` over `store.proximityTrustVault`, per-manager `ReplayCache` (24 h/10k).
- `FriendSessionTrustPolicy.isTrustedProximityPeer` hard-codes `true` — friendship is NOT enforced by
  the shared handshake; hearts' friends-only gates live in `ProximityHeartManager` and must move with
  any port.
- Sealing is per-message ephemeral X25519 ECDH → HKDF → ChaChaPoly against the peer's long-term KA
  key; no session keys exist. `sealingRequiredTypes = [friendPhoto, recipeShare, clothingCatalog,
  friendHeart]` is fail-closed at the receiver.
- The mesh supports pairwise sealed unicast to one slot (`sendEnvelope(via:sealed:)`), used by photos;
  full payloads go to **active slots only** (max 3 of 5; lightweight slots are heartbeats-only;
  distance re-ranking can demote mid-session).
- Beacons/heartbeats exist ONLY inside committed sessions. The only pre-connection channels are
  advertiser discoveryInfo (static per advertiser start; restart to change) and the **unused**
  `invitePeer(withContext:)` field.
- No production radio advertises a fingerprint (`fp` parsing plumbing exists but is fed by a dead code
  path); the mesh invite tie-break therefore compares fingerprint-vs-displayName (asymmetric, masked
  by retry).
- `UIDevice.current.name` returns generic "iPhone" on iOS 16+ without the user-assigned-device-name
  entitlement (Fernlet doesn't hold it) — the persisted MCPeerID is a *stable* identifier but not a
  name leak.
- Vouch lists (`sendVouchList`) broadcast all unblocked trusted fingerprints to session slots (2 h
  TTL) — dormant today only because the vault is empty. Phase 2 must disable this until a feature
  needs it.
- FernletDomainModel is an SPM package: **enum/struct shape changes need a CLEAN build** (incremental
  builds mask non-exhaustive switches and can ship layout-corrupted binaries).

## Phases

### Phase 1 — Transport hardening + modular payloads  ⟵ IN PROGRESS
1. **Surface discovery failures.** Implement `didNotStartAdvertisingPeer` /
   `didNotStartBrowsingForPeers` in `MeshMultipeerSession`: os_log + optional
   `onTransportError` callback; wire into manager diagnostics where available. This class of silent
   failure (the Bonjour wall) must be impossible to ship again.
2. **Forward-tolerant PayloadType on the wire.** Envelope decodes the payload type as a raw string;
   known → enum, unknown → parked (envelope retains the raw token, exposes `isUnknownType`).
   Canonical signature bytes keep using the raw string, so signatures verify for unknown types.
   `verify()` for unknown types: schema version, expiry, signature, recipient match, replay-record —
   then SKIP payload decrypt/sealing semantics (fail-closed by non-dispatch).
   `ProximityCoordinator.handleInbound`: verified unknown-type envelope → diagnostic + silent drop,
   session stays alive (never `fail()`). Unknown types are never dispatched to handlers.
3. **Capability advertisement.** Identity intro payload gains optional `capabilities: [String]`
   (JSON-additive; absent on old clients → legacy = photos only). Carried on `PeerIdentity`,
   exposed per slot/connection, with a `peerSupports(_:)` helper so senders skip payloads the peer
   can't use.
4. **Payload handler registry.** MeshNetworkManager's hardcoded inbound switch keeps mesh-control
   types in core and gains a registration seam for feature modules (shop registers in Phase 3,
   messages in Phase 5). Unregistered known types keep today's silent drop.
5. Do NOT add `_fernlet-heart`/`_fernlet-clothes` to NSBonjourServices — both radios are deleted in
   Phase 4; declare `_fernlet-near._tcp/_udp` when Phase 4 lands.
- Tests: unknown-type envelope (signature verifies, parked, session survives, replay recorded),
  capabilities present/absent decode, registry dispatch + unregistered drop, transport-error surfacing.

### Phase 2 — Friend minting (one-sided)
- Capture peer identities (displayName, fingerprint, signing + KA keys) into a session-scoped roster
  at **slot commit** (`onSlotConnected` / promotion loop) — they must survive slot teardown because the
  review sheet fires after `leaveSession` clears slots, and the non-initiating side loses slots first.
- Per-participant "Keep X as a friend?" prompt at session end, firing on EVERY session teardown
  (not just photo-nonempty ones — `presentDisconnectReviewIfNeeded` currently guards
  `!sessionPhotos.isEmpty`). Writes `vault.trust(peer, mode: .friend)`.
- One-time presence enable prompt on first kept friend (Phase 4 dependency, gate behind the setting
  existing).
- **Disable the vouch-list broadcast** (`sendVouchList`) until a feature consumes it — Phase 2 is what
  would otherwise switch it on.
- Presence/heart rosters must filter `blockedAt`/`revokedAt`/empty-KA stub records.
- **Friend lifecycle semantics (settled by the Phase-2 capstone review):** *Remove* (revoke) =
  unfriend — reversible in person: a revoked-only peer may handshake again (friend-mode transport
  ban applies to BLOCKED keys only) and is re-offered by the keep prompt after a fresh verified
  session; *Block* = ban — silent drop at transport, never re-offered, and the keep flow must never
  revive it (`trust()` clears both timestamps, so the finalize-time guard checks blocked only).
  *Unblock* demotes a ban to "removed" (re-friendable in person, not silently restored).
- **Session-end review is model-state, not view-events:** the manager promotes the roster into a
  `pendingFriendReview` batch whenever the last committed slot disappears (merging into any
  unconsumed batch); views present off that observable state (`onChange` + `onAppear`), because the
  Social-tab layout swap destroys the presenting view in the same transaction as the `isInSession`
  flip (this also silently broke the pre-existing remote-goodbye photo review on the Social tab).
  Consume is scoped: finalize clears only the batch/entries it presented, never the live roster.

### Phase 3 — Shop onto the mesh + recipe cap (parallelizable)
**3a. Shop:**
- New `.clothingCatalog` handling registered via the Phase-1 registry; guard: accept only from
  committed slots (`slot.fingerprint != nil`), key catalogs by verified fingerprint only, mirror
  friendPhoto's blocked-fingerprint drop. Two Phase-1 review facts that make these guards
  load-bearing: (a) the registry can fire for uncommitted (pre-dwell) peers — the coordinator
  dispatches known non-core payloads with `connectedIdentity ?? pendingPeerIdentity` and no state
  gate, so the committed-slot check IS the security boundary; (b) the registry is consulted only on
  the plain-envelope dispatch path — the closed-mode encrypted-metadata inner switch
  (`handleEncryptedMetadata`) does NOT consult it, so if catalogs ever ride encrypted-metadata in
  closed mode, that inner dispatch needs extending too.
- Send own catalog once per slot on commit, pairwise sealed; advertise `shop` capability; skip peers
  without it.
- **Post-session shop window:** catalogs live from receipt until 1 h after session end / app quit /
  next session start (memory-only). No mid-session scene-dip clearing (the window already outlives
  the session; radio privacy is handled by mesh lifecycle). FriendShopView becomes the post-session
  surface on the Friends tab (normal layout is back after the session) with a window countdown;
  keep a coin-balance surface reachable outside the window (the old header badge dies with the
  clothes radio).
- **"Next session start" = first slot COMMIT, not search start** (Phase-3 capstone correction):
  `startJoin` fires automatically on every Social-tab entry and scene reactivation, so closing the
  window there destroys it before the user can ever see its only entry point. The window (and held
  catalogs) reset when a session actually FORMS — the first committed slot — mirroring why
  `pendingFriendReview` deliberately survives `startJoin`. This also makes the transient-drop case
  coherent: last slot lost mid-outing opens the window; a re-commit closes it, clears catalogs, and
  the exchange re-runs.
- **Catalog delivery must not assume commit symmetry:** the sender transmits at ITS commit but the
  receiver's registry gate requires the RECEIVER's commit — a slightly-later receiver drops the
  catalog forever under once-per-slot send tracking. Fix: a `clothingCatalogRequest` payload
  (additive-safe post-Phase-1) sent at own commit; a committed peer answers with its catalog,
  bypassing the once-per-slot guard (idempotent — receiver replaces by fingerprint). Send-tracking
  is pruned on slot eviction so a rejoining friend re-exchanges.
- Opt-out (`allowNearbyClothingShares`) becomes payload-layer: provider returns nil when off, inbound
  case drops when off, setter clears held catalogs; Settings copy updated (it no longer stops a
  radio); shop entry hidden when off.
- Delete `ProximityClothingShareManager` + its ContentView gating + FernletStore wiring; port the
  ephemerality tests to the mesh-owned shop state; mesh equivalents for `clearCatalogs` seams.
**3b. Recipe cap:**
- `MeshMultipeerSession.pauseDiscovery()/resumeDiscovery()` (stop advertiser + browser, KEEP
  instances + MCSession). Resume-before-invite is the contract (invitePeer on a stopped browser is
  undocumented — don't rely on it).
- Expose connecting-count (pendingConnectionPeers) to `shouldAcceptInvitation`; accept only when
  connections + pending == 0 (or same peer). Outbound cap in `sendRecipeShare`. Belt-and-braces
  disconnect of a race-slipped third peer via `cancelConnectPeer` (best-effort; undocumented for
  connected peers).
- **Reopen keyed on manager-level connection-record eviction** (stale-coordinator sweep included),
  NOT on MC disconnect events (a failed handshake never fires one — deadlock otherwise). Route the
  re-listen through a manager→ContentView callback so the privacy gate (opt-in/scene/tab/lock) stays
  app-side; fix the pre-existing go-dark-after-share gap the same way.
- Sender UX: connect timeout + visible rejection state (rejection is the common case under a cap);
  disable non-target rows while connecting; cap-aware `refreshDiscovery`.

### Phase 4 — Presence + hearts (deletes 2 radios)
- **SEALED-INTRODUCTION rule (Phase-4 capstone, HIGH — closes the tag-replay identity leak):**
  pairwise-DH tags defeat tag *derivation* but NOT *replay* — tags are broadcast in cleartext with
  no nonce, so a passive observer can re-advertise a friend's current-epoch tag and get a heart
  connection accepted. The original mitigation ("invitation gating") is defeated by that same replay,
  and the connection then emitted the local signed identity intro (stable signing+KA keys + display
  name) before any friend-key proof — deanonymizing the identity the ephemeral presence radio exists
  to hide. FIX: presence-originated heart connections must NOT send the identity introduction in the
  clear. Presence recognition is mutual-by-construction (both friends hold each other's vault KA
  public key — a one-sided friend never appears nearby), so both the initiating AND accepting side
  always know the intended friend's KA public key from the matched vault record and SEAL the intro to
  it (reuse `IdentityService.seal`). A replay-forger holds no matching KA private key → cannot
  decrypt → learns nothing (keys or name) in either direction; the real friend decrypts and the
  handshake proceeds. Implement as a coordinator mode: presence heart coordinators are created with
  the expected friend's KA key, seal the outbound intro to it, and open inbound intros with the local
  KA private key. Post-fix residual = only the accepted one: spoof "friend nearby" + bait a
  connection that fails WITHOUT leaking identity.
- **Hearts require presence (Phase-4 capstone, MEDIUM):** reachability = the presence nearby set, so
  hearts-ON + presence-OFF renders every friend perpetually "Not nearby" with a misleading hint. The
  hearts affordance must make presence a prerequisite (enable presence / "Turn on Nearby Friends to
  send hearts"), never silently dead.
- **Manager-Task lifetime rule (from the Phase-3 crash):** every escaping `Task` spawned by a
  proximity manager must capture `[weak self]` — a strong capture extends the manager's lifetime
  past its owning store and any store touch then aborts on the `unowned` reference
  (`swift_abortRetainUnowned`, seen in the test host). PresenceManager inherits this rule from day
  one; `noteSlotCommittedForShop` is the canonical session-formation detector for any
  formation-keyed feature (e.g. the presence-enable prompt).
- `PresenceManager` on `fernlet-near` (+ NSBonjourServices entries). Advertises `{v, tags}` only.
- **Pairwise static-static X25519 DH tags** (NOT public-key-hash tags — anyone who ever completed a
  handshake holds your public keys and could compute those forever; pairwise-DH is the only
  observer-opaque construction and the only one where blocking someone removes their tag):
  tag = truncated HMAC(HKDF(DH(myKA_priv, friendKA_pub)), epoch ~15 min), ≥8 bytes, match ±1 epoch,
  debounce the nearby set across the epoch advertiser-restart flap. TXT budget caps ~20-25 tags —
  cap the roster, prefer most-recently-seen friends.
- Identifier hygiene: presence uses its own per-start random, NEVER-persisted MCPeerID (do not write
  through the shared FileMCPeerIDStore — it would clobber the stable ID other radios rely on).
  Honest privacy claim: opaque to passive observers + cross-launch unlinkable; an active adversary
  replaying tags within an epoch can spoof "friend nearby" — accepted residual, plus invitation
  gating below.
- **Hearts**: FriendListView reachability = presence match; send = on-demand short-lived pairwise
  connection ON the presence service (invite → 1-RTT handshake → programmatic auto-commit → sealed
  `friendHeart` → teardown incl. `cancelConnectPeer` so zombies don't accumulate toward the 8-peer
  MCSession cap). Carry the heart manager's vault gates (send: verified fingerprint matches vault
  record; receive: trusted + not blocked/revoked). Inbound invitation gate: accept only inviters whose
  discovered tag matches a friend (defer/reject on the pre-discovery race); optionally a tag-derived
  MAC in the (unused) invitation context.
- **New heart rules:** no daily limit in person; 1-per-5-min per-friend rate limit on send, mirrored
  on receive; consume-on-send retained. Ledger: replace day-key gating for proximity hearts with
  5-min rate keys; keep id-dedup.
- `allowNearbyHearts` new homes: send-side gate, receive-side drop, FriendListView row render.
  Hearts-off + presence-on means a friend can see you nearby but a heart to you silently drops —
  document; consider a `hearts` capability bit later.
- Define PresenceManager's observable contract BEFORE deleting the heart radio (nearby set,
  heartSendState: connecting/handshaking/sent/failed) — FriendListView rewires in the same change.
- Delete `ProximityHeartManager` + `ProximityClothingShareManager` radios, their ContentView
  listeners, and Settings copy that implies radio control. Port HeartShareTests manager-half to the
  new flow.

### Phase 5 — Temporary messages
- New `tempMessage` payload kind via the Phase-1 registry + `messages` capability. Sealed pairwise to
  active slots; session-scoped store cleared on session end (both graceful goodbye and transport
  loss); never persisted, never synced, excluded from snapshots. UI TBD (inside the in-session
  surface).

## Sequencing & ritual
Phase 1 → 2 → (3a ∥ 3b) → 4 → 5. Note 3a/3b both edit the ContentView listener chain + FernletStore
setter block — land those files in one of the two and rebase the other. Per-phase: build
(CLEAN when FernletDomainModel shape changes) + owning test suites in batches + review before moving
on. Branch: `claude/mesh-redesign`.

## Evidence base
Six reader reports + four critic reports (file:line-cited) from the 2026-07-10 investigation live in
the session scratchpad; the durable conclusions are all folded into this document.
