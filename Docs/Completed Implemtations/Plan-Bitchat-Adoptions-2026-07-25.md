> **CLOSED 2026-08-09 — SHIPPED.** Merged 2026-07-26 (`claude/bitchat-adoptions`): wire2 sealed-payload compress+pad framing, the enforced privacy-wipe coverage checklist, the offline-hearts CloudKit dead-drop with one-time-prekey forward secrecy and day-rotating HMAC tags, and the QR verification ceremony for non-UWB commits. Still deferred by decision: §E BLE wake-on-proximity presence (design sketch only — revisit with the Android/cross-platform transport work). Live tracker: [RemainingWork-2026-07-19.md](../RemainingWork-2026-07-19.md).

# Plan — bitchat-inspired mesh adoptions (2026-07-25)

Branch: `claude/bitchat-adoptions` (off `cb798e4`). Source analysis: bitchat repo review + Fernlet
Proximity inventory, 2026-07-25 session. bitchat is Unlicense/public domain — patterns and code may
be adapted freely; Fernlet remains Apache-2.0.

## Locked decisions (user, 2026-07-25)

| Decision | Call |
| --- | --- |
| Background BLE wake-on-proximity presence | **Deferred** — design sketch only (§E); this round's new pieces must stay transport-agnostic so BLE can slot in later (revisit with Android/cross-platform work). |
| Panic gesture | **Skipped** entirely. |
| Offline hearts transport | CloudKit **public-DB** E2EE dead-drop + proximity hybrid (decided 2026-06; this round builds it). |
| Away-delivery consent | **Opt-in**, nothing-silent: first away-send shows a consent sheet; Settings toggle `heartsAwayDelivery`, default OFF. Applies to both writing and fetching drops. Independent of the iCloud *sync* storage preference (public DB ≠ private sync) — copy must say so. |
| Messages | Stay session-only (locked 2026-07-10). Dead-drop carries **hearts only**. |

## Increments (build order)

Order rationale: 1 first (wipe registry pattern exists before new stores are added), 2 before 3
(drop envelopes use the wire2 framing), 4 last (independent, but shares PayloadType/capability
files with 2–3).

### Increment 1 — Panic-wipe coverage (bitchat lesson: wipe checklist)

bitchat's `docs/privacy-assessment.md` enumerates every store its panic wipe must clear. Fernlet
already fought "writers that resurrect data after a wipe" (#18 round); the store count keeps
growing. Make coverage auditable:

- **Docs/PrivacyWipeCoverage.md** — table: persistence surface → wiped by (file:line) → test.
  Includes a **deliberate-exceptions** section (e.g. the self-ban record survives delete-all BY
  DESIGN, per 2026-07-17 decision).
- **WipeRegistry** (name may follow existing delete-all structure): each subsystem registers a
  `wipePersistentData()`; delete-all iterates the registry. Unit test asserts the registry covers a
  curated manifest of store identifiers — adding a store without registering it fails the test.
- Audit results (2026-07-25, against `FernletStore.deleteAllData` :3442): the wipe already covers
  the ledgers, vault, media stores, activities, widget mirror, AI stores, and repository purge.
  **Confirmed gaps to fix:**
  - `IdentityService.wipe()` exists (`:653`) with ZERO call sites — proximity identity keys
    survive delete-all (and keychain survives even reinstall on iOS). Wire it in; identity
    regenerates lazily; friends must re-friend in person afterward (correct "fresh start"
    semantics, same as bitchat's panic wipe — flag as a product-behavior change).
  - Backup-escrow keychain rows (synced + local, content-addressed) — orphaned once sealed
    backups are disabled earlier in the wipe; delete them.
  - ColumnCrypto device keys (`deviceJournalKey`/`deviceWorryKey`) — orphaned after repository
    purge; delete (verify lazy-regen per store).
  - `PrivateMediaKeyStore` keychain key — same orphan treatment.
  - `SessionMessageStore` — memory-only but not cleared in the wipe path; clear for hygiene.
  - Presence manager not stopped/reset during wipe; stop + reset transient state.
  **Deliberate exceptions (document, do not "fix"):** app-lock keychain (separate "Reset app
  lock" action, by design), MilestoneLedger (documented at FernletStore :3657), friend-photo wall
  (`deleteAllSessionPhotos` intentionally not called — product decision), ModerationBanStore
  self-ban (survives by design per 2026-07-17 decision).
- Consent-surface conventions (for Increment 3): destructive = `DestructiveConfirmation` alert
  style; first-use opt-in = plain `.alert` two-button pattern (`SettingsSheet` "Turn on Nearby
  Friends?" precedent); toggle home = SettingsSheet Privacy section (:266-341) with
  explicit-Binding + footer; `heartsAwayDelivery` is a plain additive Bool in FernletSettings
  (`decodeIfPresent ?? false` — no token channel needed), matching its `allowNearbyHearts`
  sibling.
- New stores from Increments 2–4 (prekeys, outbox, drop dedup, drop settings) must register here.

### Increment 2 — Sealed-envelope hygiene: compress + pad ("wire2")

bitchat pads non-fragment packets to 256/512/1024/2048 buckets and zlib-compresses ≥100 B payloads.
Fernlet seals raw JSON (base64 photo payloads +33%) with no length hiding.

- New capability token **`wire2`** (FernletDomainModel — ⚠️ enum/struct change ⇒ **CLEAN build**,
  per FernletDomainModel clean-build hazard).
- Sealed-plaintext framing, in-band and self-describing: first byte is a format tag. Legacy raw
  JSON starts `{` (0x7B), so `0x01` (deflate+padded) / `0x02` (raw+padded) are unambiguous. Opener:
  tag byte → new path; anything else → legacy raw.
- Order matters: **compress → pad → seal** (padding after compression blunts CRIME-class length
  inference). Buckets 256/512/1024/2048/4096 then 4 KiB multiples; trailing 2-byte pad length.
  Compress only when ≥128 B and actually smaller (Compression framework, zlib/deflate).
- Inflate bomb guard: hard cap on decompressed size (16 MiB; existing photo receiver caps stay).
- Send gate AND parse gate are both keyed on the capability handshake, deterministically: when both
  sides advertise `wire2`, the sender MUST frame and the receiver parses framed; otherwise legacy
  raw on both ends. The format tag byte is an integrity check, not a discriminator — no
  byte-sniffing of legacy payloads. Dead-drop envelopes (Increment 3) always use wire2 framing —
  their only readers are new clients by construction.
- Placement: framing happens inside `IdentityService.seal/open` behind a `framing:` parameter
  (default legacy), threaded from the three seal call sites (`MeshNetworkManager.sendEnvelope`,
  `ProximityCoordinator.sealIfNeeded`, sealed-introduction) which know the peer's capabilities.
- All FernletDomainModel token additions for this whole plan land in ONE commit here — capability
  tokens `wire2` + `heartsAway`, payload types `friendHeartDrop` + `verifyChallenge` +
  `verifyResponse` — so the clean-build hazard is paid once; later increments add behavior only.
- Tests: round-trip both formats, legacy interop both directions, bucket boundaries, bomb guard,
  compressibility cutover.

### Increment 3 — Offline hearts dead-drop (the flagship)

Decided architecture (2026-06) + two bitchat refinements: **one-time prekey bundles** for forward
secrecy and **day-rotating HMAC recipient tags** for unlinkable public-DB addressing.

**Wall placement (S3, agent-confirmed):** crypto, tags, outbox, and scheduling live on the sealed
side (ProximityKit). CloudKitSync gets only a dumb ferry for opaque `{tag: String, payload: Data}`
records, implementing a protocol declared in **FernletDomainModel** — already a dependency of both
ProximityKit and CloudKitSync, and already the deliberate home of `HeartPayload` for exactly this
Phase-6 seam. FernletDomainModel is NOT MainActor-defaulted, so the protocol must be
`nonisolated`/`Sendable`-clean. CloudKitSync never imports ProximityKit (which deps
PrivateMediaStore); ProximityKit never imports CloudKit. ~~S3BoundaryTests has no CloudKit-import
rule — the compiler wall is the enforcement~~ *(stale as of 2026-07-26:
`FernletTests/S3BoundaryTests.swift` now enforces both directions — ProximityKit ⊬ CloudKit and
CloudKitSync ⊬ ProximityKit — with comment-vs-import discrimination tested)*; CloudKitSync is the
only module with `import CloudKit` today. Transport reuses the existing injection precedent
(`CloudKitRecordDatabase` protocol + `SystemCloudKitRecordDatabase`) for testability; container
`iCloud.MBO.Fernlet`; this is the app's FIRST use of the public database (private-only today);
entitlements already carry CloudKit + aps. The envelope is transport-agnostic by construction
(mesh, CloudKit, or a future BLE courier can carry the same bytes).

Sealed side (ProximityKit):
- **HeartPrekeyStore** — batches of 16 X25519 one-time prekeys; private halves in a keychain-backed
  blob (ThisDeviceOnly, non-synchronizable — FS keys must never sync; identity is per-device
  already). Public bundle Ed25519-signed over canonical bytes `{v, bundleID, created, expires
  (30 d), keys[{id, pub}]}`. Top up when unused < 4 or nearing expiry.
- **Prekey gossip** — new payload type `prekeyBundle`, sealed, sent to kept friends on session
  commit and presence handshake; gated on new capability **`heartsAway`**. Friend bundles cached
  per signing key with a per-recipient consumed-ID set (sender-side one-time marking).
- **Consumed-prekey policy (deviation from bitchat, documented):** recipient retains private halves
  until bundle expiry (≤30 d) rather than delete-on-use + 48 h grace — two friends may race the
  same prekey since gossip is broadcast. FS window = bundle lifetime, still a massive improvement
  over static-forever; monthly rotation bounds compromise exposure.
- **Day tags** — `dropTag = HMAC-SHA256(K_pair, "fernlet.heartdrop.tag.v1" ‖ day_be64 ‖
  senderKApub)` truncated to 16 B (hex string for CK). `K_pair = HKDF(staticDH(me, friend), salt
  "fernlet.heartdrop.v1")` — mirrors the presence-tag derivation with a UTC-day epoch. The
  `senderKApub` term gives direction asymmetry (my outgoing tag ≠ my expected incoming tag).
  Observers (and the public DB) see only uncorrelatable-across-days opaque tags.
- **HeartDropSealer** — inner: the existing signed envelope (new payload type `friendHeartDrop`),
  wire2-framed (padded → hearts are all 256 B-class, indistinguishable). Outer:
  `[v1][prekeyID 16 B or zeros][eph pub 32][nonce 12][ct‖tag]`; ECDH against prekey when one is
  unconsumed, else **static-KA fallback** (availability over FS; flagged in header).
- **HeartDropOutbox** — persisted, sealed at rest *(the seal shipped 2026-07-26 with
  Plan-Prekeys-ProtectedLoad-CoachMesh Track A Increment 4 — the 2026-07-25 v1 wrote plaintext
  JSON under `.completeFileProtection` only)*; entries `{id, friendKey, envelope, tag, created,
  attempts, ckRecordName?}`; retry on foreground/reachability; expire 14 d; registered in the wipe
  registry. Heart *rate limiting stays in ProximityHeartLedger* (5 min/friend, consume-on-send) —
  the outbox is downstream of it.
- **HeartDropService** — send: friend absent → ledger gate → seal → outbox → transport. Fetch (on
  foreground, consent-gated): compute expected tags (kept friends × today−6…today) → batch query →
  open (prekey lookup incl. retained halves) → dedicated replay cache → ledger receive → existing
  unread/attention signal. Cleanup: delete own records > 14 d (public-DB records are
  creator-delete-only; recipients dedup instead — no ack records in v1).

Walled side (CloudKitSync):
- **HeartDropTransport** — CKRecord type `HeartDrop` `{tag: String (queryable), payload: Bytes}`,
  public DB, default zone; `upload / fetch(tags:) / deleteOwn / accountAvailable`. Dev schema
  auto-creates; **production schema promotion is an owner console action** (tracked in
  RemainingWork).

UI/consent:
- Heart button for an **absent** friend: first tap → consent sheet (house style of the destructive
  settings warnings); enabled → heart queues with a "will be delivered" state. Settings toggle
  under the proximity/social section. Copy replaces "hearts travel in person for now"
  (FriendListView + PresenceManager strings).
- No push in v1; CKQuerySubscription noted as a future upgrade.

Seam notes (agent-confirmed 2026-07-25):
- `HeartPayload` already lives in FernletDomainModel **explicitly so a Phase-6 dead-drop
  (CloudKitSync carrying pre-sealed envelopes) needs no edge into ProximityKit** (file header,
  HeartSharing.swift:5-7) — the wall placement above is the codebase's own intended seam.
- Enqueue joins at `PresenceManager.sendHeart`'s two absent-exits (:507 not-running, :517 no
  discovered peer) — enqueue instead of `failHeart` when consent is on. Pre-generate
  `HeartPayload.id` at enqueue time so receiver id-dedup holds across re-delivery.
- Receive path: `ProximityHeartLedger.recordReceivedHeart` enforces a 5-min per-sender window that
  would collapse a multi-day drop batch fetched at once. Drops get a dedicated entry point:
  id-dedup + **per-sender per-`sentAtDayKey` cap of 3**, bypassing the live 5-min window (receive-
  side flood bound, since a malicious client could ignore the sender-side 5-min consume-on-send).
- Ledger retention is 48 h / 32 hearts — NOT sufficient as drop dedup (a still-on-server record
  would re-deliver after pruning). The durable 30 d drop-dedup store is load-bearing.
- Received-heart surfacing reuses the existing bubble/glow (`pendingBubbleHeart`, `heartGlow`);
  `NotificationService.postSessionMessage`'s coalescing pattern is the template if a background
  fetch path ever lands.

Implementation deviations (as built, 2026-07-25):
- Bundle authenticity rides the SIGNED intro envelope (`IdentityRangingPayload
  .heartDropPrekeyBundle`, additive JSON key) — no second standalone bundle signature to drift.
- Recipient prekey retention = until bundle expiry (30 d) + 48 h grace, NOT delete-on-use: the
  bundle broadcasts identically to every friend, so senders race the same prekeys; FS window =
  bundle lifetime, still bounded and monthly-rotating (vs static-forever before).
- Envelope `verify` gained an OPTIONAL replay cache: `ReplayCache` rejects `createdAt` older than
  its 24 h window, which would kill every multi-day drop — the drop path passes nil and relies on
  the 30 d durable dedup (checked BEFORE verify) instead. All live-radio paths still pass one.
- The PresenceManager race-window fallback WAS wired after all (`queueAwayHeart` closure): a live
  send that finds the friend gone hands the heart to the drop (which consumed the cooldown) and
  reports `.sent`, rather than failing.
- Cleanup needs no server query: the outbox remembers uploaded recordNames and deletes them at
  the 14 d expiry. Reinstall orphans (outbox lost) linger as undecryptable blobs — accepted.
- `syncOnce()` is the deterministic test seam; production uses fire-and-forget `syncNow()` off
  the ContentView listener chain.
- SettingsSearchIndex checked at capstone: the catalog is ROUTE-level (one entry per
  `SettingsRoute`; individual toggles aren't leaves), so the inline "Deliver hearts when apart"
  toggle needs no entry. RESOLVED.

Known residual (documented, accepted): CloudKit public-DB records expose the writer's
`creatorUserRecordID` to other queriers — an observer sees *that* an iCloud user wrote N drops on a
day, never to whom. Inherent to CloudKit; consistent with the "no servers the user operates"
decision. Tags/ciphertext leak nothing linkable.

Tests: tag vectors (direction asymmetry, day rotation), sealer round-trip prekey + fallback +
grace-retention, outbox persistence/expiry/retry, service flows against a mock transport, replay
dedup, consent gating, wall check (`Scripts/spm-wall-check.sh` + S3BoundaryTests).

### Increment 4 — QR verification ceremony (non-UWB fallback hardening)

bitchat's pattern: signed `bitchat://verify` QR + in-session challenge/response. Fernlet analog
upgrades `awaitingManualCommit` (non-UWB peers — old iPhones now, Android later) to ceremony grade:

- QR: `fernlet://verify?d=<base64url(signed {v, signingPub, kaPub, ts, nonce16})>`; freshness
  ±5 min; generated with CIQRCodeGenerator, displayed from the session peer row (and friend detail
  for re-verification). Scanner reuses the shipped barcode-scanner infra with QR symbology.
- In-session binding: scanner matches the QR's signing key to a connected peer → sends sealed
  `verifyChallenge{nonce}` → peer replies `verifyResponse{sig over "fernlet.verify.v1" ‖ scannerKA
  ‖ challengeNonce ‖ qrNonce}` → verify → slot upgrades to committed (ceremony = .qr). The sealed,
  signed challenge identifies the scanner, so the displayer upgrades symmetrically.
- Both payload types sealing-required; nonces single-use. New PayloadType cases ⇒ CLEAN build.
- Tests: QR blob sign/verify + freshness window, full challenge/response state machine, wrong-key
  and replayed-nonce rejection.

### §E — BLE wake-on-proximity presence (DESIGN SKETCH ONLY, deferred)

What it would take, so this round doesn't foreclose it:
- Dual-role CoreBluetooth (central+peripheral) with state-restoration IDs; advertising carries the
  **existing presence epoch tags** (8 B HMAC tags fit BLE service-data) — the tag scheme is already
  transport-agnostic and needs zero changes. Wake path: never-expiring pending connects to
  discovered candidates; on wake, local notification "a friend is nearby", full session still
  requires foregrounding (ceremony unchanged).
- Duty cycling per bitchat's measured policy: continuous when isolated/traffic, 5 s/10 s normal,
  3 s/15 s dense; announce backoff 4 s → 15 s → 30 s.
- Costs: `bluetooth-central`/`bluetooth-peripheral` background modes + usage strings, App Review
  exposure, and a **privacy-posture change** (today: radios only foreground+unlocked+tab). Needs
  its own decision round; natural bundling with Android transport work (MC does not exist there —
  bitchat's public-domain BLE stack is the reference implementation).
- Guarantees kept this round: presence/day tags, prekey bundles, and drop envelopes carry no
  MultipeerConnectivity assumptions.

## Cross-cutting

- **Compat:** all new payload types ride the existing unknown-token parking (old clients park,
  never dispatch). New sealed framing is capability-gated. No envelope schema bump needed.
- **Shared worktree discipline:** pathspec commits only; never sweep the xcscheme plist / AGENTS.md
  noise.
- **Test cadence:** targeted per-module during increments; full suite in batches + wall check +
  clean build (DomainModel enum changes) before merge.
- Deferred out of scope: BLE build (§E), push subscriptions, ack records, hearts-away multi-device
  reconciliation beyond per-device identity (hearts are pairwise device-scoped today).
