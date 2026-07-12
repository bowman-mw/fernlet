# Kickoff prompt — Fernlet friend-social Phases 6 & 7

> Paste this into a fresh session (or just say: *"Read Docs/Phase6-7-Kickoff-Prompt.md and
> Docs/Social-AppStore-Implementation-Plan-2026-07-11.md, then implement Phase 6, then Phase 7,
> committing after each phase's tests pass."*). Phases 1–5 are already built, tested, and committed.

## Where things stand

- **Branch:** `claude/social-appstore-blockers` (off `main`). **Not pushed.**
- **Committed:** `fb3e52a` (App Store blockers + tamper-proof ban), `f5d264f` (one-hop report relay +
  ban fixes), `1c170fc` (fuzzy friend state + cached appearance), `d001839` (closeness + 8/4 slots).
  ~60 tests green.
- **Read first:** [Social-AppStore-Implementation-Plan-2026-07-11.md](Social-AppStore-Implementation-Plan-2026-07-11.md)
  (phase breakdown, module placements, S3-wall rules, the §"Phase 6" seam list) and
  [FernletSpecificationV3.md](FernletSpecificationV3.md) §9 (handshake), §10 (friend limits + trainer
  export), §15 (Activities screen), §3 (cloud-minimal types).

## The pattern to copy (established in Phases 3b + 4)

Both the moderation relay and the fuzzy-state exchange ride the friend **mesh** the same way — mirror it:

1. New sealed payload case in `FernletDomainModel/PayloadType.swift` + a `ProximityCapability` case.
2. Add sealed types to `FernletIdentityEnvelope.sealingRequiredTypes` (bodyless request payloads stay
   OUT, like `clothingCatalogRequest`).
3. `registerXHandler()` in `MeshNetworkManager.init`; a `sendX(to slot:)` called from
   `noteSlotCommittedForShop` (the commit hook), gated on `peerIdentity.supports(.yourCapability)`.
4. Provider/sink **closures** on `MeshNetworkManager`, wired from `FernletStore`'s `meshNetworkManager`
   lazy-init (see `ownModerationReportsProvider` / `friendStatePayloadProvider` / `onFriendSessionCommitted`).
5. Advertise the capability in `MeshNetworkManager.localCapabilities()` (gate on an opt-in if there is one).
- **Signing:** `IdentityService.sign(_:)` / static `verify(_:of:by:)`; canonical bytes via
  `CanonicalSignatureSerializer` (it has `canonicalBytes(for: MeshAdmissionToken)` — mirror it).
  `MeshAdmissionToken.signed/verify` in `MeshPayloads.swift` is the exact token template.
- **Device-local sidecars:** JSON in Application Support, `.completeFileProtection`, **never in the
  snapshot** (mirror `ProximityHeartLedger` / `ClosenessLedger`). Wire `clearAll()` into
  `FernletStore.resetAll()`.

## Hard rules (do not skip)

- **S3 wall:** new pure value types → `FernletDomainModel`; managers/wire → `ProximityKit`; UI → app
  target `Fernlet`. `AIProviders`/`CloudKitSync` must never import a `Private*` store. Run
  `Scripts/spm-wall-check.sh` after wire changes.
- **CLEAN build whenever you add a case to a `FernletDomainModel` enum** (`PayloadType`,
  `ProximityCapability`, …) — incremental builds mask non-exhaustive switches and ship layout-corrupted
  SIGSEGV binaries. Use `xcodebuild clean test -scheme Fernlet -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:...`.
- **Verify-then-park:** new `PayloadType`/`ProximityCapability` cases are additive-safe (old clients park
  them) — no park-mechanism edits needed.
- **Gotcha:** `MeshNetworkManager`'s `store` is `any ProximityHost` (a protocol). For a trust check use
  `store.proximityTrustVault.isTrustedProximityPeer(...)`, **not** `store.isTrustedProximityPeer(...)`.
- **Gotcha:** a type embedding `CompanionAppearance` cannot be `Sendable` (it isn't) — see
  `CachedFriendState`.
- **Ritual:** build + test per phase; **commit after each phase's tests pass** (message ends with the
  `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>` line); don't push unless asked. Exclude the
  Xcode `xcschememanagement.plist` from commits. Run new suites with `-only-testing`; the full
  `FernletTests` is ~7 min.
- **Ultracode / quality:** use multi-agent workflows for understand/design/review; implement
  sequentially (shared files + one build). **Run an adversarial review agent (opus/sonnet — the Fable
  budget is exhausted) on the join-token verification before committing Phase 6.**

---

## Phase 6 — Group Activities (proximity-only, small groups)

Design source: the 2026-07-11 Fable activities memo — **host-authoritative versioned roster +
invitee-key-bound signed join token; host-authoritative snapshot gossiped, honest staleness; the UWB
dwell IS the join ritual.** Full seam list in the plan doc §"Phase 6".

**Value types** (`FernletDomainModel/ActivityModels.swift` — pure `nonisolated Codable Sendable`):
- `ActivityDescriptor` { `activityID`, `hostFingerprint`, `hostSigningPublicKey` (trust root, pinned at
  join), `title` (sanitized via `ItemNameModeration`), `activityTypeToken` (RAW string, forward-tolerant),
  `coarseLocation` (optional text, city-granularity, **never `CLLocation`**), `createdAt`, `expiresAt`
  (**required**, ≤7 days) }. `activityParamsHash = SHA-256(canonical descriptor)`.
- `ActivityParticipant` { `fingerprint`, `displayName`, `signingPublicKey`, `keyAgreementPublicKey`, `joinedAt` }.
- `ActivityRosterSnapshot` { `schemaVersion` (**SIGNED, day one**), `activityID`, `version` (host-monotone;
  receivers keep `max`), `participants` (≤12, host included), `issuedAt`, `hostSigningPublicKey`,
  `hostSignature` }.
- `ActivityJoinToken` { `schemaVersion` (**SIGNED**), `activityID`, `activityParamsHash`, `joinerFingerprint`,
  `joinerSigningPublicKey` (bound), host keys, `grantedAt`, `expiresAt` (== descriptor), `rosterVersionAtGrant`,
  `hostSignature` }.

**Wire** (`ProximityKit/Wire/ActivityPayloads.swift` + `signed`/`verify` + `canonicalBytes` overloads):
- `PayloadType` cases (DomainModel): `activityOffer` (sealed), `activityJoinRequest` (**UNSEALED** —
  mirror `clothingCatalogRequest`, NOT in `sealingRequiredTypes`), `activityJoinGrant` (sealed),
  `activityRosterSnapshot` (sealed), `activitySync` (sealed). `ProximityCapability.activities`.
- `ActivityJoinToken.verify` — mirror `MeshAdmissionToken.verify`: `expectedActivityID` match (the outer
  payload id is **unsigned** — the `handleAdmissionGrant` lesson), expiry, `presentedKey ==
  joinerSigningPublicKey`, fingerprint/key consistency both sides, `expectedParamsHash`, single-encoder
  signature gated on the **signed** `schemaVersion` (avoid the permanent dual-verify at
  `MeshPayloads.swift`).

**Manager** (`ProximityKit/Activities/ProximityActivityManager.swift`): `@MainActor @Observable`,
memory-only roster (mirror `MeshClothingShop`); mint/verify tokens via `IdentityService` +
`CanonicalSignatureSerializer`; persist via a narrow `ProximityHost` seam (never name `FernletStore`).

**Join flow on the existing code:** host creates locally → both open join (reuse `fernlet-friend`, **no
new radio / no `NSBonjourServices` entry**) → standard handshake + UWB dwell commit (the dwell IS the
join ritual; registry committed-slot gate at `MeshNetworkManager:857`) → host sends `activityOffer` on
commit (piggyback the `noteSlotCommittedForShop` hook) → joiner `activityJoinRequest` (validate claimed
fingerprint/key == `slot.verifiedSigningPublicKey`, per `handleAdmissionRequest`) → host confirms in an
`ActivityJoinPromptSheet` (clone `MeshAdmissionPromptSheet`) → host mints the token bound to the
**transport-verified** signing key (never the request's claimed key), appends the participant, bumps the
snapshot version, signs, sends sealed `activityJoinGrant {token, snapshot}` → joiner verifies (own key +
`expectedActivityID` + paramsHash; snapshot under the pinned host key) and persists → ongoing
`activitySync` digest exchange between committed peers (`[activityID: versionHeld]`; highest verified
version wins; tokens are host-signed grow-only deltas).
- **Authorization is independent of the shared handshake:** `FriendSessionTrustPolicy.isTrustedProximityPeer`
  hard-codes `true`, so the grant must carry its own vault/`MeshAdmissionToken`-style check (exactly as
  hearts carry `isHeartEligibleFriend` independently).

**Screen** (`Fernlet/ActivitiesView.swift`): empty (Host / Join nearby) · join-in-progress (search/dwell,
offered-activities picker, waiting) · hosting (card + expiry countdown, live roster with fingerprints,
join-request prompt, per-member Remove → version bump, End) · joined (card + host name/fingerprint,
roster, token status, Leave) · shared roster view with a **"Roster as of \<issuedAt\> (v\<n\>)"**
staleness banner · expired/ended history.

**Deferred / out of scope:** cloud roster/sync of activities; cascading / member-admits-member trust;
groups >12; remote/link joins; host succession, key rotation, compromise recovery; signed revocation
tombstones; persistent-roster member voting; activity content (chat/logs/live location); rename/mutable
params.

**Tests:** token sign→verify round-trip; a token for activity A rejected for B; expired token rejected; a
non-eligible peer's grant refused despite a session commit; an unknown `activityJoin*` payload parks on a
legacy client (no brick).
**DoD:** a host creates an Activity; a nearby peer sends a join request and receives a signed,
activity-scoped, replay-protected grant; the Activities screen shows the roster; authorization is
independent of the shared handshake.

---

## Phase 7 — Trainer / Nutritionist export

> **Assumption:** "Phase 7" = the trainer/nutritionist export that was deferred when this effort was
> scoped (owner picked the core social pillar + Group Activities, not trainer export). If you meant
> something else (e.g. the S3 module-wall retrofit for the new types, or finalizing the App Privacy
> nutrition-label metadata), replace this section — the rest of the prompt still stands.

Design source: spec §10 "Trainer and Nutritionist Sharing" + `Docs/RemainingWork-2026-06-23.md`.
Recommended shape: an **in-app** `Trainer/Nutritionist Export` view (not a separate app) that shares over
the same proximity transport, with a reviewable consent screen — nothing sent until the user confirms
exactly what will go.

**Export bundle (explicit + reviewable):** workouts over time (names, sets, reps, weights, duration, RPE);
nutrition summaries (per-day macro + micronutrient totals from `MealLog` snapshots, meal names, nutrient
gaps, derived eating patterns — **not** recipe ingredient lists, only the computed per-serving values that
were logged); hydration, sleep summary, sickness windows, derived signals, and goal type **only when the
user chooses to include them**.

**Excluded by default (hard wall):** raw journal text, Sensitive/Tier-2 memory, period data, photos,
friend data, location, recipe ingredient details, any hidden/debug-only fields. Reuse the allowlist
discipline from Phase 1's `Fernlet/DataExportBuilder.swift` (fail-closed projection, not copy-and-strip).

**Transport:** sealed pairwise over the mesh. There is **vestigial scaffolding** to reconcile first —
`PayloadType.trainerPlan`/`trainerPlanDelta`, `MultipeerServiceType.trainer = "fernlet-coach"` (still in
`Info.plist` `NSBonjourServices`), `TrainerAuditLog`, `ProximityMode.trainer` — verify what's reusable
vs. delete; `TrainerProximityService` itself was removed. A consent/review screen must list exactly what
will be sent and require explicit confirmation before the send.

**Tests:** the assembled bundle provably excludes every hard-excluded category (mirror the Phase-1 export
exclusion tests); consent is required before any send; sealed on the wire.
**DoD:** a user can review + send a curated workout/nutrition bundle to a nearby trainer over the mesh,
with the excluded categories provably absent.

---

*Everything above respects the S3 wall and the verify-then-park / clean-build / sidecar-not-synced
conventions the first five phases established. Build, test, and commit one phase at a time.*
