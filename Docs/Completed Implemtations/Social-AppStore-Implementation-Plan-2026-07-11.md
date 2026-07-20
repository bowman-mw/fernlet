> **CLOSED 2026-07-19 — SHIPPED.** All 6 phases verified on `main`; the A1 privacy-policy copy was finalized 2026-07-19 (contact + effective date + Apache-2.0 LICENSE). Deferred by scope: cloud cascading-trust for large group activities (tracker). Live tracker: [RemainingWork-2026-07-19.md](../RemainingWork-2026-07-19.md).

# Fernlet — App Store Blockers + Friend Social Layer — Implementation Plan (2026-07-11)

Consolidates a 7-reader seam-map (Opus) + three deep design memos (Fable) on the hardest
sub-problems: the tamper-resistant moderation/ban system, group-activity trust, and closeness +
fuzzy-state privacy. Every `file:line` below was verified against source. This doc is the
implementation bible; the deeper rationale lives in the design-memo transcripts (2026-07-11).

**Legend:** `[ ]` todo · `[~]` in progress · `[x]` done · 🔒 privacy/security-critical

---

## Scope (owner-approved 2026-07-11)

**App Store blockers:** A1 privacy policy (draft + in-app screen), A2 content report + on-device
moderation/ban, A3 export-my-data, A4 spec/label docs (drop the Bluetooth key).
**Friend social:** B1 fuzzy state, B2 cached appearance, B3 friend slots, B4 closeness, B5 group
activities. **Deferred this pass:** trainer/nutritionist export; cloud cascading-trust for large
group activities.

### Decisions locked

| # | Decision | Choice |
|---|---|---|
| Privacy policy | draft + in-app screen; owner hosts URL for Connect | ✅ `Docs/Privacy-Policy.md` drafted |
| Reporting | hide + block + on-device log, with escalation | ✅ (design below) |
| Bluetooth key | leave out; fix spec §18 | ✅ |
| Ban scope | per-device receiver-side enforcement + device-scoped self-ban keychain row + synced courtesy flag | ✅ |
| Report delivery | one-hop, reporter→own vault friends; **no dead-drop needed** | ✅ |
| Thresholds | item-unlistable ≥2 distinct vault reporters; designer-ban ≥3 distinct items (each ≥2 reporters); 180-day decay; per-reporter cap 2 items/designer; 30-day ban | ✅ tunable constants |
| Closeness storage | per-device sidecar (NOT synced), day-bucketed counters | ✅ |
| Fuzzy cadence | handshake-only (+ verified heart connection); never on presence beacon | ✅ |
| Fuzzy staleness | <48h plain · 2–30d "as of last meeting" · >30d hide state | ✅ |
| `allowNearbyFriendState` | new opt-in, **default off**, separate from hearts/presence | ✅ |
| Export locked-state | export non-sealed always; journal plaintext only for unlocked days, else labeled omitted | ✅ |
| Export social graph | include friends (names + fingerprints) as a labeled section | ✅ |
| Activity coarse location | optional host-typed **text**, city-granularity, never `CLLocation` | ✅ |
| **Slot semantics** | **12 friends total: 8 core + 4 close.** Close = the 4 highest-closeness friends, auto-promoted (owner-confirmed 2026-07-11; mechanism documented in spec §10). | ✅ |

---

## Cross-cutting constraints (every phase)

- **🔒 S3 module wall (hard build error).** Only `AIProviders` + `CloudKitSync` are walled off from
  `Private*` sealed stores. **New pure value types → `FernletDomainModel`** (reachable everywhere,
  cannot name a sealed type). Deterministic math/engines → `FernletDomainModel`/`FernletScoring`.
  Managers/wire → `ProximityKit`. UI + store wiring → app target `Fernlet`. One clock helper →
  `FernletFoundation`. After wire-type edits run `Scripts/spm-wall-check.sh`; if the DAG changes,
  `Scripts/spm-wall-selftest.sh`. New social/moderation types must NEVER enter an `AIContext` typed
  payload — add them to the forbidden-fields tests.
- **CLEAN-build hazard.** Adding cases/fields to `FernletDomainModel` enums (`PayloadType`,
  `ProximityCapability`, `CompanionState`, the trust record) requires a **clean** build — incremental
  builds mask non-exhaustive switches and ship layout-corrupted binaries (SIGSEGV). → **Phase 0
  lands every enum/field once.**
- **Verify-then-park (modular payloads).** New `PayloadType` cases are additive string rawValues;
  `FernletIdentityEnvelope` parks unknown tokens and `ProximityCoordinator.handleInbound` guards
  them (`:713`); new `ProximityCapability` cases auto-skip legacy (nil-capability) peers via
  `supports(_:)`. **No park-mechanism edits ever needed** — old clients tolerate all new kinds.
- **Sealing fail-closed.** Sensitive payloads MUST be in `FernletIdentityEnvelope.sealingRequiredTypes`
  (`:170`); bodyless request payloads MUST NOT (mirror `clothingCatalogRequest`).
- **Two dispatch paths.** The handler registry is consulted only on the plain-envelope default
  (`MeshNetworkManager:848-864`); the closed-mode `handleEncryptedMetadata:1974` inner switch is NOT
  a registry. Keep all new payloads on the plain-envelope + sealed-pairwise path; never ride
  `meshEncryptedMetadata`.
- **Manager-Task lifetime.** Escaping `Task`s in `PresenceManager`/`MeshNetworkManager` need
  `[weak self]` + re-bind across suspensions (see `startEpochRotation:387`) or they abort the store's
  `unowned` ref.
- **Untrusted wire.** Sanitize/clamp every received appearance texture/name, fuzzy code, report field
  (`ItemGridTexture.sanitized`, `ClothingShopLimits.sanitizedForShop`, `ItemNameModeration.sanitizedName`,
  shape checks à la `HeartPayload.isValidDayKey`) before persist/render — the vault record is synced.
- **Build/test ritual per phase:** clean build (`xcodebuild build-for-testing -scheme Fernlet
  -destination 'platform=iOS Simulator,name=iPhone 17'`) → owning-suite tests in batches → wall check.

### Module-placement summary

| New type | Module |
|---|---|
| `FriendFuzzyState` (+ `CompanionState.fuzzy`), `FriendStatePayload` | FernletDomainModel |
| `fuzzyState(for:)`, `ClosenessMath`, `CloseSlotAssignment` | FernletScoring |
| `FriendInteractionDayCounts` DTO | FernletDomainModel |
| `FriendSlotTier`, new `ProximityTrustedPeerRecord` fields | FernletDomainModel |
| `PayloadType.{friendState,itemReport,moderationNotice,activityOffer,activityJoinRequest,activityJoinGrant,activityRosterSnapshot,activitySync}` + `ProximityCapability.{friendState,activities}` | FernletDomainModel |
| `ModerationLedgerEntry`, `ModerationEconomy`, `ClothingModerationLimits`, content-hash fn | FernletDomainModel |
| `Activity*` value types (`ActivityDescriptor`, `ActivityParticipant`, `ActivityRosterSnapshot`, `ActivityJoinToken`) | FernletDomainModel |
| `FernletDataExport` DTO | FernletDomainModel |
| `MonotonicClock` (`mach_continuous_time`) | FernletFoundation |
| `ClosenessLedger` (sidecar), `FriendStateCache` (sidecar) | ProximityKit (`Closeness/`) |
| moderation `*Payload`, `ModerationVault`, `ModerationBanClock` | ProximityKit (`Wire/`, `Trust/`) |
| `ProximityActivityManager` | ProximityKit (`Activities/`) |
| `DataExportBuilder`, `PrivacyPolicyView`, `ActivitiesView`, report/moderation UI | app target Fernlet |

---

## Phase 0 — Shared domain model + wire vocabulary (foundation, clean build) 🔒

Land ALL enum cases/capabilities/record fields once (clean-build hazard). Inert cases with no
sender are harmless (auto-parked).

- `PayloadType.swift:45` — add the 8 payload cases above (dotted string rawValues,
  `fernlet.<area>.<name>.v1`). `:70` — add `ProximityCapability.friendState`, `.activities`.
- `FernletIdentityEnvelope.swift:170` — add the sealed ones to `sealingRequiredTypes`
  (`friendState`, `itemReport`, `moderationNotice`, `activityOffer`, `activityJoinGrant`,
  `activityRosterSnapshot`, `activitySync`). Exclude bodyless `activityJoinRequest`.
- `CompanionModels.swift:339` — add `FriendFuzzyState {thriving=1,okay=2,struggling=3}` (Int-raw,
  constant-length wire); mark the `CompanionAppearance` enum tree `Sendable`.
- `FernletScoring/Scoring.swift` — add `fuzzyState(for: CompanionState) -> FriendFuzzyState` beside
  `state(for:)`: `thriving→thriving`, `okay→okay`, `tired/resting/sick→struggling`.
- `ProximityPersistenceRecords.swift:38` — add to `ProximityTrustedPeerRecord`: `slotTier`,
  `closenessScore` (display cache; source of truth is the sidecar), `reportedAt`, `reportReason`.
  **Extend the hand-written `init(from:)` at `:81` with `decodeIfPresent … ?? default` for each** +
  defaulted memberwise-init params. (Fuzzy state + cached appearance live in the `FriendStateCache`
  sidecar, NOT the synced record — see Phase 4.)
- New value-type files in `FernletDomainModel/` (shapes in the per-phase sections): `FriendStatePayload`,
  `FriendSlotTier`, `FriendInteractionDayCounts`, `ModerationLedgerEntry`+`ReportReason`,
  `ModerationEconomy`+`ClothingModerationLimits`, `ActivityModels.swift` (all four activity types),
  `FernletDataExport`.
- New `FernletFoundation/MonotonicClock.swift` — `mach_continuous_time()`-based (counts sleep),
  injectable provider mirroring `FernletUptimeProviding`.

**Tests:** `ProximityTrustedPeerRecord` populated round-trip + forward-compat (decode missing keys →
defaults, no throw); `CompanionState.fuzzy` truth table (sick/resting/tired→struggling);
`FriendStatePayload` structural test = no score/goal/component field + constant byte-length across
states 1/2/3; `S3BoundaryTests` + `spm-wall-check.sh` green. **DoD:** clean build + full suite green;
no downstream phase touches these three hot files again.

---

## Phase 1 — Privacy Policy + Export my data + docs (A1, A3, A4)

Mesh-independent; the paperwork half of submission. Depends on Phase 0 (`FernletDataExport`).

- **A1** `SettingsSheet.swift:114` (Privacy `Section`) — `NavigationLink("Privacy Policy") {
  PrivacyPolicyView() }` onto the existing `NavigationStack`. New `Fernlet/PrivacyPolicyView.swift`
  renders `Docs/Privacy-Policy.md` (bundle the .md as a resource or embed as a constant). Policy text
  drafted; **needs the `{{PLACEHOLDER}}` fills + legal review before submission.**
- **A3** `PrivacyDataSettingsView.swift:208` — `exportDataCard` in `privacyControls` after
  `localBackupCard`, behind the existing fresh-verification gate (`:130`); handle nil `store`. New
  `Fernlet/DataExportBuilder.swift` (or `FernletStore.exportUserDataArchive()` near `resetAll():1835`)
  assembles `FernletDataExport` from **live decrypted in-memory state** (NOT `forStorage`, which blanks
  journals); use `resetAll()`'s collection list as the completeness checklist; hydrate journal
  plaintext from `JournalNarrativeRepository.narratives(forDayKeys:contentKey:)` **only when unlocked**.
  Reuse `ConnectionInspector.exportAsJSON()` encoder config (`[.prettyPrinted,.sortedKeys]`, ISO-8601);
  write to `temporaryDirectory` with `.completeFileProtection`; present `ShareLink(item: url)`; delete
  on dismiss; `FernletAuditLog.log("privacy.export.created")`.
  - 🔒 **EXCLUDE:** period narratives + `PeriodTrackerStore` cycle + `IntimacyLogRepository` +
    `healthContext.cycle/.intimate` + `dailyScores.periodPhase` (strip via `storedDailyScores`);
    Tier-2/`TierTwoMemoryRecord` in production (DEBUG-gated + labeled only); Worry Box notes; **photo
    bytes** (keep `Meal.photoID` refs only); crypto identity keys. Reuse `SanitizedDay`'s cycle/intimate
    strip list but KEEP journal text (it's the user's own content).
- **A4** Edit spec §18 to drop `NSBluetoothAlwaysUsageDescription` (already absent; transport is Local
  Network Bonjour `_fernlet-*` + UWB). Author `Docs/App-Privacy-Nutrition-Labels.md` (privacy-first,
  on-device; own data in CloudKit *private* DB = not developer-collected, not tracking; peer-to-peer
  friend exchange). Note: `PrivacyInfo.xcprivacy` `NSPrivacyCollectedDataTypes` is currently empty —
  keep it so unless a social type later syncs.

**Tests:** export round-trips back into `FernletDataExport`; excluded sections provably absent
(no period/intimate keys, no photo bytes, `periodPhase == nil`, `sensitiveMemory == nil` in a
release-config test); locked-state export never crashes and labels omitted journals honestly.
**DoD:** user reads policy in-app + exports a JSON archive via share sheet; archive proven free of
sealed data; spec + label doc updated.

---

## Phase 2 — Content report + block + on-device log (A2 part 1) 🔒

The actual UGC submission blocker (Apple Guideline 1.2: report + block + filter + published contact),
fully local. Depends on Phase 0 (`ModerationLedgerEntry`/`ReportReason`).

- 🔒 Reports key on `catalog.senderFingerprint` (transport-verified), **never** `payload.designerID`
  (attacker-settable; `FernletStore:706` re-randomizes on collision).
- `FriendShopView.swift` `itemTile` — "Report item…" affordance → `store.reportClothingItem(item, catalog)`.
- `DisposableCameraView.swift:1156` — "Report…" `Button(role:.destructive)` beside `manager.block(participant)`.
- `FriendListView.swift` — "Report" in swipe actions (`:102`) + detail card (`:235`); badge reported peers.
- `ProximityTrustVault.swift:81` — `report(signingPublicKey:reason:blockAlso:)` modeled on `block()`:
  stamp `reportedAt`/`reportReason`, optionally `blockedAt`/`revokedAt` (block-and-report default),
  append a `TrainerAuditEvent` (add tolerant `Kind.peerReported`), `onChange()`.
- `FernletStore.swift:901` — `reportProximityPeer(...)` beside `blockProximityPeer`; `refreshRoster()` after.
- `SettingsSheet.swift:168` — persistent "Report a problem" + published support contact/EULA link.
- On-device moderation log: append `ModerationLedgerEntry` rows locally. 🔒 **UI copy must never imply a
  report is transmitted** (no server).

**Tests:** `report(blockAlso:true)` sets fields + audit + persists + refreshes; shop report keys to
verified fingerprint not designer UUID; reported item hidden locally immediately. **DoD:** report from
friend list / shop / in-session roster; report = hide + block + log; Settings report path + support
contact exist.

---

## Phase 3 — Moderation escalation + anti-bypass store ban (A2 part 2) 🔒🔒

**Core architecture (from the ban design memo):** there is **no authoritative global count**; each
device computes a **local verdict** over reports it personally verified. Reports propagate **one hop**:
a reporter hands their own Ed25519-signed report to *their* vault-trusted friends during committed
sessions; a device counts a report only if the reporter's signing key is in **its own** vault. No
transitive relay, no merged tally. Enforcement is **receiver-side** (tombstones/peer-bans on victims'
devices) — that's the load-bearing layer; self-ban is honest-client compliance only.

**Data shapes**
- `ModerationLedgerEntry` (FernletDomainModel, mirrors `CoinLedgerEntry`): deterministic id
  `report:<reporterFP16>:<contentHashHex>` / `retract:…`; `kind` (tolerant decode); `reporterSigningPublicKey`;
  `subjectSigningPublicKey` (transport-VERIFIED at receipt); `itemID` (display only, NOT dedup key);
  `contentHash = SHA256(sanitized texture bytes ‖ slot rawValue)`; `reasonToken` (parked raw);
  `reporterSeq` (per-reporter monotone); `createdAt` (clamped to receipt on ingest).
- `ModerationReportPayload` (ProximityKit/Wire, mirrors `ClothingSharePayloads`): `entries` (≤32; only
  rows SIGNED BY THE SENDER) + `perEntrySignature[]` (Ed25519 by reporter over canonical bytes).
  Receiver drops any entry whose `reporterSigningPublicKey ≠ transport-verified sender` (one-hop) and
  counts only if sender ∈ vault & unblocked. `PayloadType.itemReport` (sealed).
- `ModerationNoticePayload` (informs an honest designer, reporter identities STRIPPED):
  `{contentHash, distinctReporterCount}`, sender-vouched. `PayloadType.moderationNotice` (sealed).
- **BanRecord** (keychain JSON, service `com.fernlet.moderation`, `AfterFirstUnlockThisDeviceOnly`,
  `synchronizable:false`): `banID`, `subject` (`selfStore` | `peerDesigner(fp16)`), `durationSeconds
  = 2_592_000`, `startedAtWall` (absolute `timeIntervalSinceReferenceDate` — NEVER Calendar/dayKey),
  `creditedMonotonicSeconds`, `creditedWallSeconds`, `lastCheckUptime`, `lastCheckWall`,
  `maxObservedWall` (high-water trap), `tamperCount`. Plus a device-scoped `selfBan.device` row
  (not pubkey-keyed) so identity-wipe can't reset a self-ban. Synced settings hold a reporter-free
  self-ban **courtesy flag** only.

**🔒 Anti-bypass storage:** `com.fernlet.moderation` keychain service is **never** touched by
`IdentityService.wipe()`, `FernletLockService.reset()`, or any "reset all data". Keychain survives
app delete+reinstall (identity does too). Read errors → **fail closed for selling** (no listing, no
broadcast, no `shop` capability), fail open for browsing. Read-back-verify every write (mirror
`FernletLockService.storeVerified`).

**🔒 BanClock (extends `FernletLockService` monotonic pattern for 30 days).** Compute-on-read
(launch/foreground + lazily in each gate). Per check:
1. Same boot (`nowUptime+1 ≥ lastCheckUptime`): credit monotonic delta; also credit the *excess*
   `wallDelta − monotonicDelta` when `0 ≤ wallDelta` (covers sleep — `systemUptime`/`mach_continuous_time`
   nuance; use `MonotonicClock` = `mach_continuous_time` which counts sleep to minimize wall trust).
2. Reboot (`nowUptime+1 < lastCheckUptime`): credit `clamp(nowWall − lastCheckWall, 0, ∞)` to wall,
   re-anchor uptime.
3. Always update `maxObservedWall = max(maxObservedWall, nowWall)`; persist (verified).
4. **Rollback trap:** `nowWall + slack < maxObservedWall` (slack ≈26h) ⇒ tamper: zero
   `creditedWallSeconds`, `tamperCount++`, audit `storeBan.clockRegressionDetected`. Monotonic credit
   never revoked.
5. Expiry iff `creditedMonotonic + creditedWall ≥ duration` AND no active regression.
   → rollback *extends* the ban; jump-forward is caught on return by the trap; permanent-clock-ahead is
   self-punishing (skews every dayKey feature) and accepted.

**Verdict rules / thresholds** (`ClothingModerationLimits`): accepted reporters = self + distinct
vault-trusted keys with a live (non-retracted, <180d) report for the subject; one reporter counts once
per contentHash (structural via id) and toward **≤2 distinct items** per designer.
- 1 report = immediate local: tombstone contentHash (hide in grid + buy path), `vault.block(subject)`,
  append row; offer undo (unblock + un-tombstone + `retract:` row, higher `reporterSeq`).
- **Item unlistable:** receiver-side ≥2 distinct accepted reporters for a contentHash ⇒ permanent local
  tombstone (filtered before reaching `MeshClothingShop`; buy refused; content-keyed → survives
  itemID/name/price/identity rotation). Designer-side ≥3 notices ⇒ force `isShareable=false` +
  `ShopListingResult.delisted`.
- **Designer 30-day ban:** receiver-side ≥3 distinct contentHashes from one verified designer key, each
  ≥2 reporters, within decay ⇒ `peerDesigner` BanRecord (drop that key's catalogs 30 BanClock days).
  Designer-side same tally over notices ⇒ `selfStore` BanRecord.

**Enforcement seams:** `FernletStore.listCustomItemForSale` gate (+ `ShopListingResult.delisted/.storeBanned(remaining:)`);
`buildShopCatalog`/`localCatalogProvider` return nil/empty under self-ban; `MeshNetworkManager` suppress
`shop` capability while self-banned, extend `isBlockedFingerprint` drop with `isBannedDesigner`, register
`.itemReport`/`.moderationNotice` handlers (committed-slot + verified-fingerprint gate, per-sender
rate-limit like `MeshClothingShop.perSenderRateLimitSeconds:47`); `MeshClothingShop.receiveCatalog` filter
tombstoned contentHashes via an injected `isTombstoned` closure; `FriendShopView` buy refuses tombstoned.
Audit every state change (`storeBan.applied/expired/clockRegressionDetected/rebootFallback`).

**Module note:** `ModerationBanClock` needs `KeychainItem` (FernletFoundation) + a local
`FernletUptimeProviding`-shaped seam — do **not** import `FernletLock` (drags sealed deps into ProximityKit).

**Tests (injectable clock/date):** reinstall (wipe container → keychain survives → ban active); clock
forward same boot (unchanged); reboot + forward (high-water refuses credit); sleep accrual (monotonic
advances); Sybil (N rows one fingerprint count once; N vault keys trip threshold; non-vault sender
dropped); one-hop (entry not signed by sender dropped); enforcement (banned `buildShopCatalog`/provider
empty, `listCustomItemForSale` `.storeBanned`); keychain isolation (`FernletLockService.reset()` +
`IdentityService.wipe()` don't clear `com.fernlet.moderation`); undo/retract terminal.
**DoD:** distinct verified reports make an item unlistable; enough reported items ban the store 1 month;
ban survives reinstall + clock rollback, enforced at list + broadcast; anomalies audited; residual
escapes (identity reset, device wipe, permanent-clock-ahead, patched client) documented as accepted.

---

## Phase 4 — Fuzzy friend state + cached appearance (B1+B2, one payload) 🔒

Depends on Phase 0. B1+B2 share transport → one sealed `FriendStatePayload` + appearance snapshot.

- 🔒 `FriendStatePayload` (FernletDomainModel): `{format, version, id: UUID, state: Int}` — **constant
  length** (int code 1/2/3, fixed-width fields) so ciphertext length can't leak the state. Boundary
  check: reject unless format/version match and `state ∈ {1,2,3}`. Appearance snapshot = the user's
  `CompanionAppearance` sub-value only (never the settings blob), carrying **unresolved** `.state`
  palette choices.
- New opt-in `allowNearbyFriendState` (default **off**, mirror `allowNearbyHearts`, separate).
- Providers on `presenceManager` (mirror `clothingShop.localCatalogProvider:116`):
  `wellbeingProvider = { store.companionState.fuzzy }`, `appearanceProvider = { store.settings.companionAppearance }`.
- **Send cadence:** on friend-slot commit + opportunistically on a verified heart connection; gated on
  `isHeartEligibleFriend:890` + `peerIdentity.supports(.friendState)` + opt-in. Piggyback the presence
  heart connection where present (respect 8-peer MCSession + `maxHeartConnections=4` caps). 🔒 **Never
  on the presence beacon** (would leak logging/snapshot timing).
- **Receive:** add a `.friendState` branch to `PresenceManager.proximityCoordinator(didReceive:)` (the
  `.friendHeart:854` sibling — the presence handler is NOT the mesh registry). Re-check eligibility,
  sanitize appearance + validate fuzzy code, write to a new `FriendStateCache` sidecar (ProximityKit,
  `FriendStateCache.json`, `.completeFileProtection`, **NOT synced**): `(fuzzyState, appearance, capturedAt)`
  per fingerprint. Purge rows on block/revoke/resetAll.
- **Render:** `FriendListView.swift:269` (`heartRow`) — `CompanionView(state: cachedFuzzy.representativeState,
  appearance: cachedAppearance)` + a fuzzy label chip, never a number. 🔒 Render `.state`-palette slots
  from the **fuzzy** value only (struggling → `tired` visual); sender never pre-resolves `.state` colors
  (unit-tested invariant) — else the 5-way state leaks via color.
- **Staleness (from `capturedAt`/`lastSeenAt`):** <48h plain · 2–30d "from when you last met, N days ago"
  quieter · >30d hide state (neutral silhouette + "It's been a while").

**Tests:** e2e sender `.sick`→struggling; payload carries no score/goal + constant byte-length; receiver
caches + renders `representativeState`; true 5-way never reconstructable; unsealed `.friendState` rejected;
opt-out drops send+receive; legacy peer skipped, unknown token parks; hostile appearance clamped; `.state`
palette renders from fuzzy only. **DoD:** two opted-in nearby friends exchange a sealed snapshot; friend
list shows fuzzy chip + cached avatar with honest staleness; no numeric/goal/component/isSick ever crosses
wire or render.

---

## Phase 5 — Closeness score + friend slots (B3+B4) 🔒

Deterministic, no-AI, trailing-30-day. Depends on Phase 0. Parallel to Phase 4 except both edit
`FriendListView.heartRow` + `FernletStore` (sequence 4→5).

- **New `ClosenessLedger` sidecar** (ProximityKit `Closeness/`, mirror `ProximityHeartLedger`:
  `ClosenessLedger.json`, `.completeFileProtection`, **NOT in `FernletSnapshot`**, purged on
  block/revoke/resetAll). Day-bucketed capped counters only (no timestamps/names/durations):
  `fingerprint → [dayKey → {sessions 0–2, photoSessions 0–1, sharesAccepted 0–1, heartSent 0–1,
  heartReceived 0–1}]`. Fed from existing paths independent of the diagnostics inspector: session on
  slot commit; photoSession on develop/review completion; sharesAccepted on user-accept of a recipe/
  clothing share; heartSent/heartReceived alongside the heart-ledger writes. Future day keys clamped to today.
- **Formula** (`ClosenessMath`, FernletScoring — pure, deterministic, unit-tested to fixtures): per day
  `points = 5·min(sessions,2) + 3·min(photoSessions,1) + 2·min(sharesAccepted,1) + min(heartSent,1) +
  min(heartReceived,1) + [heartSent≥1 && heartReceived≥1]`, capped at 10; `weight(age) = (31−age)/31`;
  `closeness = Σ weight·points` over 31 day-buckets. 🔒 Hearts capped at 1/direction/day for scoring
  (the 5-min wire limit is abuse-control, not scoring) so heart-pumping can't outrank a real meetup.
- **Slot assignment** (`CloseSlotAssignment`, FernletScoring): eligible = up to **12** active friends
  (`blocked==nil && revoked==nil`); order `closeness desc, firstAcceptedAt asc, fingerprint asc`. The
  top-4 hold the **close** slots, the next up-to-8 the **core** slots. Evaluate **once/day at
  local-midnight rollover** (not per write). Vacancy fills freely; a challenger evicts the lowest close
  incumbent only if `challenger ≥ incumbent + 8`; incumbents immune for first **3 days**
  (`slotEnteredAt`); **≤1 close-slot swap per evaluation** (largest margin); block/revoke vacates immediately.
- Vault writers: `recomputeCloseness(now:)` + `assignSlotTiers()` (index-mutate + `onChange()`), after
  every mint/block/revoke/encounter + on foreground. Enforce the **≤12** cap at mint in
  `keepProximityFriends:838` (evict the lowest-closeness **core** friend — never a close friend — or
  decline). Render tier/closeness badges in `statusBadge`.
  🔒 Closeness/slots stay device-local (slot state in the sidecar, per closeness memo).

**Tests:** fixture ledger → deterministic top-4 close; >30d events excluded; slot hysteresis (near-equal
friends never trade; margin+dwell honored; ≤1 swap); heart-pump capped; recompute idempotent; purge on
block/revoke. **DoD:** each active friend has a deterministic 30-day closeness; top-4 = close; ≤8 cap
enforced at mint; tiers recompute + persist on roster change; no AI.

---

## Phase 6 — Group Activities (B5) 🔒

Greenfield (no `Activity` scaffolding exists). Proximity/host-handshake, small-group only. Depends on
Phase 0. Land last.

**Architecture (from the activities memo):** an Activity is a **host-signed, versioned roster**;
membership is a **host-signed, invitee-key-bound `ActivityJoinToken`** minted only after the existing
UWB dwell-commit. Roster consistency = **host-authoritative versioned snapshot, gossiped opportunistically,
honest about staleness** (highest verified version wins; anyone may relay a self-authenticating snapshot;
tokens are host-signed grow-only deltas). Signed `schemaVersion` on token + snapshot **from day one**
(avoids the `MeshAdmissionToken` dual-verify trap).

- Value types (FernletDomainModel `ActivityModels.swift`, nonisolated Sendable Codable): `ActivityDescriptor`
  (activityID, hostFingerprint, hostSigningPublicKey [trust root, pinned at join], title [sanitized],
  activityTypeToken [raw string, forward-tolerant], coarseLocation [optional text, city-granularity],
  createdAt, expiresAt [REQUIRED, ≤7d]); `ActivityParticipant`; `ActivityRosterSnapshot` (signed
  schemaVersion, version [host-monotone], participants [≤12, host included], hostSignature);
  `ActivityJoinToken` (signed schemaVersion, activityID, activityParamsHash, joinerSigningPublicKey
  [bound], host keys, grantedAt, expiresAt [==descriptor], rosterVersionAtGrant, hostSignature).
- Wire (ProximityKit `Wire/ActivityPayloads.swift`) + `signed`/`verify` + `canonicalBytes` overloads in
  `CanonicalSignatureSerializer` (needs `@MainActor IdentityService`). Payload cases: `activityOffer`
  (sealed), `activityJoinRequest` (unsealed, bodyless-ish), `activityJoinGrant` (sealed, token+snapshot),
  `activityRosterSnapshot` (sealed), `activitySync` (sealed digest).
- `ProximityActivityManager` (ProximityKit `Activities/`, `@MainActor @Observable`, memory-only roster
  like `MeshClothingShop`); register handlers on the Phase-1 registry (`MeshNetworkManager:755`); persist
  via a narrow `ProximityHost` seam (never name `FernletStore`).
- Join flow on existing code: create → both open join (reuse `fernlet-friend`, no new radio/Bonjour) →
  standard handshake + UWB dwell commit (the dwell IS the join ritual; registry committed-slot gate
  `MeshNetworkManager:857`) → host sends `activityOffer` on commit (piggyback `noteSlotCommittedForShop`
  pattern) → joiner `activityJoinRequest` (validate claimed fp/key == `slot.verifiedSigningPublicKey`,
  per `handleAdmissionRequest`) → host confirms in `ActivityJoinPromptSheet` (clone `MeshAdmissionPromptSheet`)
  → host mints token bound to the **transport-verified** signing key, appends participant, bumps version,
  signs, sends sealed `activityJoinGrant{token,snapshot}` → joiner verifies (own key + expectedActivityID
  + paramsHash; snapshot under pinned host key) + persists; dup join idempotent by signing key → ongoing
  `activitySync` digest exchange between committed peers.
- Revocation = higher-version snapshot (host-only). Members: leave = local delete; block = vault block.
  Host offline ⇒ activity persists (display) until `expiresAt`; no new members without host in v1. GC on
  launch/daily prunes expired descriptors/tokens/snapshots. Caps: ≤3 hosted, ≤10 joined, roster ≤12,
  offer list ≤3/commit, `activitySync` reply rate-limited.
- **Screen** (`ActivitiesView`, app target): empty (host / join nearby) · join-in-progress (dwell +
  offered-activities picker + waiting) · hosting (card + countdown + live roster + join-request prompt +
  per-member remove + end) · joined (card + host fp + roster + token status + leave) · shared roster view
  with staleness banner "Roster as of <date>" · expired/ended (history).

**Deferred:** cloud roster / CloudKit sync of activities; cascading/member-admits-member trust; groups
>12; remote/link joins; host succession/key rotation; signed revocation tombstones; member voting on
persistent rosters; activity content (chat/logs/live location); rename/mutable params.

**Tests:** token sign→verify round-trip; token for A rejected for B; expired token rejected; non-eligible
peer's grant refused despite commit; unknown `.activityJoin*` parks on legacy client. **DoD:** host creates
an activity; nearby peer join-requests + gets a signed, activity-scoped, replay-protected grant; Activities
screen shows roster; authorization independent of the shared handshake.

---

## Sequencing

`0 → {1, 2, 4, 6}`; `2 → 3`; `3` needs 0's `MonotonicClock`/keychain; `5 → 0` (after 4 for shared
`FriendListView`/`FernletStore` seams). **Critical path for submission: 0 → 1 → 2** (policy, export,
report/block). Hardening + social: 3, 4, 5, 6. Same-file adjacencies: `FriendListView.heartRow` (2/4/5 —
sequence or split subviews); `MeshNetworkManager` init handler block (3/6 — additive registers);
`SettingsSheet`/`PrivacyDataSettingsView` (1→2→3). All `PayloadType`/record/`CompanionModels` edits are
Phase 0 only.

## Top correctness risks
1. Ban anti-bypass (keychain `com.fernlet.moderation` dedicated service survives reinstall; BanClock
   `max(wall,monotonic)` + high-water trap; `mach_continuous_time` for sleep; receiver-side is
   load-bearing). 2. Fuzzy privacy invariant (derive from enum not score; constant-length payload;
   `.state` renders from fuzzy). 3. Hand-written `init(from:)` needs a `decodeIfPresent` per field.
4. Two dispatch paths (registry vs closed-mode inner switch). 5. Sealing fail-closed membership.
6. Sanitize all wire input before persist/render (synced record). 7. Export from live state, exclude
   sealed, `.completeFileProtection`, never via a walled module.
