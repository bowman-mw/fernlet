# Plan — sidecar durability, prekey coverage, coach-path posture (2026-07-26)

> **Status: EXECUTED and merged 2026-07-27 as `fe81476`** — Tracks **A** and **B** in full, Track C
> **Increment 8**, and **Increment 10** as the test-driven hardening subset. Track C's **Increment 9
> is the one part still unbuilt, and it was always a checklist rather than build work**: the coach
> dead-drop is the off-week *secondary* channel, so it waits behind the in-person session. What
> Increment 10 shipped is the hardening *ahead* of that session — the trainer tap gate that deadlocked
> on all hardware, `CoachVerificationCeremony`, `CoachSessionTrustPolicy` (a coach is not a friend, so
> the friend policy's unconditional `isTrustedProximityPeer` must never be injected into a coach
> coordinator), the pre-decrypt wire-size gate, and the role split written down as an executable
> contract. **None of it has a production caller yet** — the coach session manager and its UI are the
> outstanding work, and `Docs/FileIndex.md` flags those types accordingly. Read the increments below
> as built specifications except Increment 9.
>
> Two adversarial review rounds on this branch found 11 real defects in the work, two of which would
> have shipped silent data loss; the merge commit message is the record.

Branch: `claude/heartdrop-durability` (off `main` @ `db40340`). Source: three research passes over the
just-merged bitchat-adoptions round (the bitchat-adoptions plan, since retired from the tree)
plus a spot-check of the shipped code. bitchat remains the pattern reference (Unlicense); nothing is
copied verbatim.

Three tracks. **Track A ships first because it fixes bugs that are live today**; B is a coverage
improvement to a property that is degraded but working. B lands after A because both edit
`HeartDropPeerBundleCache` and A rewrites its load/persist seam — doing B first means rewriting B.

**Track C changed shape on 2026-07-26.** It was written as a decision record plus one small UI fix,
on the assumption that the in-person coach session might never ship. The owner has since confirmed
the opposite: **the in-person mesh session is the primary coach channel**, with iMessage + CloudKit
as the off-week fallback. Track C is therefore real build work — read "Coach channel model" at the
top of Track C before anything else in it, and note that it now contradicts
`Docs/FernletCoach-Specification-2026-07-19.md`, which still has the priority the other way round.

A and C are independent and can proceed in either order or in parallel; A/B share files, C does not
touch them.

## Spot-check corrections to the research passes

Read before trusting the increments below; these are the places the reports were imprecise.

| Claim | Truth at `db40340` |
| --- | --- |
| "Nothing constructs or begins a `.trainer` coordinator" | True **in production**. The test footprint is far larger than an earlier draft said: 32 `begin(… mode: .trainer)` call sites across 5 files (ProximityCoordinatorTests 26, TrainerProximityServiceTests, HeartShareTests, MeshClothingShopTests, RecipeShareCodecTests), plus ~21 more `.trainer` record constructions in ConnectionInspectorTests / ProximityTrustVaultTests / FernletSnapshotRoundTripTests. Direction unchanged, and the size strengthens the do-not-delete decision. The trainer branches are test-covered dead code, not untested dead code. There is no `TrainerProximityService` type — the test file is named after one that does not exist. |
| "S3BoundaryTests has no CloudKit-import rule" (Increment 3 note, plan doc :100) | **Stale.** `Tests/FernletTests/S3BoundaryTests.swift:226-227` now enforces both directions: ProximityKit ⊬ CloudKit, CloudKitSync ⊬ ProximityKit, with comment-vs-import discrimination tested at :252-260. That earlier plan line should be treated as superseded. |
| "`heartDropPrekeyBundleProvider` is zero-argument" | Confirmed: `ProximityCoordinator.swift:771`, wired identically at `MeshNetworkManager.swift:1535` and `PresenceManager.swift:637`. |
| "`advertisedFingerprint` is always nil on the mesh radio" | Confirmed: `currentDiscoveryInfo()` (`MeshNetworkManager.swift:1438-1450`) publishes only `v`/`sid`/`name`/`meshID`/`meshName`/`memberCount`. No `fp`. |
| "`FernletStore` cannot be constructed in the background" | Confirmed by construction, not by policy: `FernletStoreLoader.startIfNeeded()` (`FernletStoreLoader.swift:19`) is called only from `FernletApp.swift:112` inside the `WindowGroup` `.task`, and `retry()` (:25). `heartDropService` is a `lazy var` at `FernletStore.swift:218`. But `Info.plist:6-9` already declares `UIBackgroundModes = remote-notification`, and `App/FernletWidgets/GuidedWorkoutLiveActivityIntents.swift` + `App/Fernlet/FernletAppIntents.swift` both run `openAppWhenRun = false` in the app process from a locked device. The isolation is one wiring line thick. |
| "Outbox `load`/`persist` swallow everything" | Confirmed: `HeartDropOutbox.swift:221-225` (`try?` ×2, absent/unreadable/corrupt all → `[]`) and `:227-232` (`try?` write, no dirty flag). Same shape at `HeartDropDedupStore.persist` (:342), `HeartDropPeerBundleCache` init (:44-49) / `persist` (:139), and `ProximityHeartLedger.load/save` (:219-241). |

---

## Locked decisions

| Decision | Call |
| --- | --- |
| Track order | **A (durability) → B (signed prekey); C (coach) is independent.** A fixes live data-loss and must precede B (shared files). C no longer depends on either — it became real build work when the in-person session was confirmed as the primary coach channel, so it can run in parallel or first if the coach feature is the priority. |
| Sidecar failure model | **Refuse, don't merge.** bitchat merges a pending snapshot because its router accumulates real messages during a locked BLE wake. Fernlet has no writer that runs while a sidecar is unloaded, so every store fails closed instead. Saves ~400 lines of merge bookkeeping. |
| Sidecar protection class | **Stays `.completeFileProtection`.** Seal at rest, do NOT relax to `completeUntilFirstUserAuthentication`. Sealing alone is a strict gain; sealing + AFU key is a net loss (see Increment 4 rationale). |
| Per-friend disjoint prekey sets (research "Design B") | **Not doing.** It tightens the FS window on drops that already have FS while doing nothing about the drops that have none. Reasoning and the conditions that would reopen it are in "Not doing". |
| `prekeyBundle` PayloadType / second FernletDomainModel clean build | **Not doing this round.** Only the per-friend mesh path needs it, and per-friend is not shipping. |
| Coach proximity session / coach QR ceremony | **REQUIRED — reversed 2026-07-26 (owner).** The in-person mesh is the PRIMARY coach channel, not a deferred nice-to-have. See "Coach channel model" below; Increment 10 is promoted from optional to blocking. |
| O1 outbox vs restore | **Device-scoped.** `ThisDeviceOnly` seal key + `isExcludedFromBackup` on the sidecars, so file and key share one fate. Also removes today's cleartext friend-graph from the iCloud backup. |
| O2 signed-prekey window | **14 d seal window → 29 d retention**, plus an invariant test that `spkRetention < bundleLifetime + expiryGrace` — so nothing this change introduces is ever the longest-lived key on the device. |
| O3 push / `CKQuerySubscription` for hearts | **No.** A subscription hands CloudKit a standing registration of your whole pairwise tag set — a durable server-side description of the social graph, strictly worse than today's burst of foreground queries. If latency is the complaint, post a local notification when a foreground fetch lands a heart (`NotificationService` already does this elsewhere). **Consequence: the protection-class relaxation is off the table and Track A stays pure bug-fixing.** |
| O4 corrupt outbox | **Salvage element-wise, DISCARD the remainder, audit-log the count.** Do not quarantine to a file: nobody can act on a corrupt outbox blob, and keeping one creates a second friend-key privacy surface the wipe would have to own. Requires per-row decodability (NDJSON or a lossy array decode) — `[Entry]` fails atomically. |
| O5 ledger in this round | **Yes.** Track A's product is "no heart sidecar silently resets"; four of five stores makes it a convention, not an invariant, and leaves the broken pattern for the next reader to copy. |
| O6 coach `channelTag` | **Neither pole — rotate on a COARSE epoch (monthly, or weekly).** Same construction as the hearts day tag with a bigger divisor. Subscriptions churn 12–52×/year instead of 365, while an observer's correlation window drops from the whole relationship to one epoch. Resolves the §3.4 conflict without sacrificing either goal. |
| `ProximityMode.trainer` + the four reserved trainer `PayloadType` cases | **Do not delete.** `.trainer` is the decode freeze-default for `ProximityTrustedPeerRecord.mode` (`ProximityPersistenceRecords.swift:91-92`). Removing it is both a FernletDomainModel clean-build change and a persisted-compat break on every existing vault row. |

### RESOLVED — owner, 2026-07-26

O1-O6 are answered in the locked table above; the reasoning that produced each is in this session's
walkthrough. **O7 was not answered but CORRECTED** — the question assumed the in-person session was
optional. It is the primary channel. See below.

Two values are deliberately still soft, and neither blocks a build: O2's exact constants (14 d/29 d is
the recommendation; the invariant test is what actually matters) and O6's epoch length (monthly vs
weekly — pick when the coach transport is written, since it trades push latency against correlation
window).


---

# Track A — sidecar durability (Increments 1-4)

## Increment 1 — `ProtectedSidecar<Value>` state machine

**New file:** `FernletKit/Sources/ProximityKit/HeartSharing/ProtectedSidecar.swift` (~180 lines,
`@MainActor`, generic over `Value: Codable`). Nothing consumes it yet.

```
enum LoadOutcome { case loaded, absent, deferred(Error), corrupt(Error) }
enum State { case ready, unavailable }

final class ProtectedSidecar<Value: Codable> {
    init(fileURL:, empty: @autoclosure () -> Value, seal: SidecarSeal? = nil,
         auditPrefix: String, readData: (URL) throws -> Data = Data.init(contentsOf:),
         observeProtectedData: Bool = true)
    var state: State { get }
    func read() -> Value?                                   // nil while `.unavailable`
    @discardableResult func mutate(_ body: (inout Value) -> Void) -> Bool   // false = refused
    @discardableResult func retryLoad() -> Bool
    func wipe()
}
```

Read classification — this is the whole point, because today's `try?` collapses three cases into one:

1. `FileManager.fileExists` false → `.absent` → empty value, state `.ready`.
2. `Data(contentsOf:)` **throws** → `.deferred` → state `.unavailable`. Deliberately coarse: any read
   error is treated as transient. That is the safe direction and matches bitchat's `CourierStore`.
3. Read succeeded, decode threw → `.corrupt` → per-store policy (Increment 2), audit-logged.
4. Decoded → `.ready`.

Persist returns `Bool`. **A failed write must never cause a later reload from disk.** The two
failures are different and need different handling — conflating them was a design error caught in
review, and the naive version would have regressed the exact durability Increment 3 exists to fix:

| Situation | Retry rule |
| --- | --- |
| A value WAS loaded (or minted) and a `persist` failed | Keep the in-memory value as the truth and **re-persist it**. Never re-read the file: the on-disk copy is older, and re-loading would discard the unpersisted mutation — for `markUploaded` that mutation IS the `recordName`, the one field nothing can reconstruct once the record is on the server. |
| No value was ever loaded (state is `.unavailable` from a failed READ) | Re-attempt the **load**. There is nothing in memory to preserve. |

So `.unavailable` must distinguish "never loaded" from "loaded, but the last write failed". Model it
as two states (e.g. `.unloaded(retryable)` vs `.dirty(value)`), not one flag.

Note this is **not** the `HeartPrekeyStore.persist` pattern (`HeartPrekeyStore.swift:169-188`, which
clears `cachedState` on failure) — an earlier draft cited it as precedent and that was wrong. There
the discard happens *before* the external effect: a bundle whose persist failed is never gossiped
(`currentBundle()` :103), so forgetting it is free. Here the failure happens *after* the external
effect — the record is already on the public database — so forgetting is precisely the harm.

Today's code accidentally gets this right: `markUploaded` (`HeartDropOutbox.swift:109-113`) mutates
memory before `persist()` (:227-232), so the name survives in memory and any later successful write
(`enqueue`/`recordAttempt`/`remove`) commits it. The name is lost only if the process dies first.
Whatever `ProtectedSidecar` does, it must not be worse than that.

Retry is driven by **both** of:
- **On access** — `read()`/`mutate()` re-attempt while `.unavailable`. Deterministic and testable,
  needs no UIKit. Must carry a retry floor (see risk).
- **Proactively** — `UIApplication.protectedDataDidBecomeAvailableNotification` observer registered
  in `init`, hopping `Task { @MainActor in self?.retryLoad() }`. Guarded `#if canImport(UIKit)`.
  ProximityKit already imports UIKit in four files (`Mesh/MeshNetworkManager.swift:4`,
  `Engine/ProximityCoordinator.swift:5`, `Presence/PresenceManager.swift:51`,
  `Transport/MeshMultipeerSession.swift:4`) and the package is iOS-only — no manifest change, no wall
  implication. If UIKit ever goes away (an Android carve), the on-access retry is a complete
  fallback; the notification is pure latency.

`readData` is injected so tests can simulate "protected data unavailable" without a device.

**Tests:** deferred→recover, absent-vs-corrupt discrimination, persist-failure flips state,
`wipe()` removes primary + quarantine paths.

**Risk (medium, and specific):** `hasCapacity`/`hasDailyCapacity`/`pendingCount` are read from view
bodies (`FriendListView.swift:441`). A naive on-access retry means a failing file read per render.
Cache the failure with a retry floor, or gate retries to sync passes + the notification only.

**Risk (low but sharp):** the notification block is `nonisolated` under Swift 6 while the class is
MainActor-isolated. It must not touch state directly; hop first. Remove the observer in `deinit`.

## Increment 2 — adopt in the three heart sidecars, fail-closed

**Files:** `HeartDropOutbox.swift` (both classes), `HeartDropPeerBundleCache.swift`.

Replace `entries`/`state`/`peers` + `load`/`persist` with a `ProtectedSidecar` instance. Behaviour
while `.unavailable`:

| Call site | Behaviour | Consequence |
| --- | --- | --- |
| `HeartDropOutbox.enqueue` (:98) | return `false` | surfaced as new `QueueOutcome.storageUnavailable` (Increment 3) |
| `HeartDropOutbox.markUploaded` (:109) | report persist failure to caller | Increment 3 turns it into an orphan log |
| `HeartDropOutbox.remove` (:127) / `removeUnchanged` (:142) | no-op, report `false` | never mutate an unloaded state |
| `HeartDropDedupStore.recordIfNew` (:281) / `acceptIfWithinDailyBudget` (:292) | return `false` | drop not accepted, record stays on server, next sync re-fetches. Strictly fail-closed: no double-delivery, no budget reset |
| `HeartDropPeerBundleCache.consumePrekey` (:89) | return `nil` | seal to the static key — the existing documented fallback, availability preserved |
| `HeartDropPeerBundleCache.store` (:59) / `returnPrekey` (:108) | no-op | bundle re-gossips at the next verified intro |

**The dangerous read-only accessors.** `uploadedRecordNames()` (:192) and `snapshot()` (:200) feed
`purgeDeadDrop` (`HeartDropService.swift:483`) and `hasStrandedDeadDropRecords()` (:537). An unloaded
outbox returning *zero uploaded records* is exactly the "the UI says it's gone when it isn't" lie the
derived-state work at `FernletStore.swift:1225-1231` exists to kill. These must return an explicitly
unknown answer that the caller propagates, not an empty array.

**Corruption policy, per store** (deviation from bitchat, deliberate — the stakes differ):
- **Outbox: element-wise lossy decode.** Decode `[FailableEntry]`, keep what parses. This preserves
  `recordName`s across an additive `Entry` field, which is the single highest-consequence loss in the
  subsystem (a lost record name = a permanently undeletable public-DB record; creator-delete-only).
  If nothing parses, quarantine to `HeartDropOutbox.json.corrupt`, log `heartdrop.outbox.corrupt`,
  raise a delivery problem, and add the quarantine path to `wipeForDeleteAll` (:205). See O4.
- **Dedup + peer bundles: corrupt → empty**, overwritable. Neither loss is irrecoverable (a
  re-delivered heart is a duplicate bubble; a lost consumption mark degrades FS for one send).

**Tests:** deferred-then-recover per store; refuse-to-overwrite; corrupt-outbox salvage keeps a
`recordName`; `snapshot()`/`uploadedRecordNames()` do not report empty while unavailable.

## Increment 3 — surface it (nothing-silent) + close the `flush` divergence

**Files:** `HeartDropService.swift`, `App/Fernlet/FriendListView.swift`, and (O5) `ProximityHeartLedger.swift`.

- Add `QueueOutcome.storageUnavailable` (enum at `HeartDropService.swift:26`) and
  `DeliveryProblem.storageUnavailable` (:41). `refreshDeliveryProblem` (:344) raises it when any
  sidecar is `.unavailable`. `runSync` (:306) calls `retryLoad()` on all three before doing anything
  — the sync pass is the natural recovery tick.
- Three exhaustive switches must gain the cases: `recordAwayOutcome` (`FriendListView.swift:549`),
  `AwayHeartsCopy.friendRowLine` (:745), `AwayHeartsCopy.settingsLine` (:761). Copy in the existing
  register, e.g. "Fernlet couldn't reach its own notes just now — unlock and reopen to send hearts."
- **The live bug this closes:** `flush` (`HeartDropService.swift:323-340`) awaits
  `transport.upload(...)` then calls `markUploaded` → `persist()`. Lock the device across that await
  and the `.completeFileProtection` write fails, swallowed by `try?`. The record name is lost while
  the record is on the public database — permanently unnameable. The code already logs
  `heartdrop.upload.orphaned` (:331) for the *cancellation* sibling of this case; it just never
  learned about the write-failure sibling. Now `markUploaded` reports, and the caller logs + raises
  rather than continuing as if the name were durable.
- **(O5, optional)** `ProximityHeartLedger.load`/`save` (:219-241) is the identical shape and holds
  `receivedHearts` + the rate-limit maps. ~20 lines to adopt. A wiped ledger re-opens the 5-minute
  receive gate.

**Deviation from the research pass:** these enums live in ProximityKit, an SPM package target, **not**
in FernletDomainModel — so the documented clean-build hazard does not formally apply. It is the same
*mechanism* though (cross-module enum layout + incremental builds masking non-exhaustive switches).
Do a clean build after this increment anyway; one build is cheap, a layout-corrupted binary is not.

**Tests:** `markUploaded`-write-failure produces the orphan log and a delivery problem; the three
copy switches compile and return non-nil for the new case; consent-off still short-circuits first.

## Increment 4 — seal the sidecars at rest, keep `.completeFileProtection`

**New file:** `HeartDropSidecarKey.swift` (~70 lines) + the `SidecarSeal` injection in the three stores.

ChaChaPoly, 256-bit key, keychain service `com.fernlet.heartdrop`, account `sidecarSealKey`,
`synchronizable: false`, accessibility per **O1**. Read-back-verify the key before sealing anything
(bitchat's `MessageOutboxStore` does this at :622-633 — without it a full or locked keychain silently
drops the key while you happily write unrecoverable ciphertext). Version-prefix the file so a
plaintext v0 file is read once and rewritten sealed: one-way migration, no dual-format read path to
maintain afterwards.

**"File exists + key definitively `errSecItemNotFound`" is unrecoverable, not deferred.** Dedup and
peer-bundles: delete and continue. **Outbox: quarantine and raise a delivery problem** — deleting it
silently strands public-DB records.

**Why the protection class stays.** What the plaintext file exposes today, precisely:
`friendSigningKey` is a stable Ed25519 public key that joins directly against `proximityTrustVault`,
so it names *which specific friend*; `createdAt` gives the second; `recordName` proves *this device*
wrote *that* public-DB record, and combined with CloudKit's `creatorUserRecordID` (the residual
already accepted at `HeartDropCloudTransport.swift:11-13`) links an iCloud account to a specific
friend-pair inbox. That is a timestamped log of who the user sent affection to, with proof of
authorship — squarely what `ProximityHeartLedger.swift:4-9` says must never leave the device.

Under `.completeFileProtection` none of it is readable while locked. Under
`completeUntilFirstUserAuthentication` it is readable in the AFU state — the state commercial
forensic extraction actually targets. **Sealing alone is a strict gain** (closes file-only
exfiltration: unencrypted backups, app-group read bugs, a future export walker). **Sealing plus an
AFU-accessible key is a net loss**: the AFU attacker who gets nothing today would get both the
ciphertext and the key that opens it, in exchange for only the backup case. So: seal, and do not
touch the class. Relax only when a background writer genuinely exists, and then only for the store
that writer must write, moving the key's accessibility in the same commit.

**No wipe-manifest work.** `KeychainItem.deleteAll(service:)` (`FernletFoundation/KeychainHelpers.swift:125-133`)
deletes by service across all accounts, and `HeartPrekeyStore.wipeForDeleteAll()` (:121-124) already
calls it for `com.fernlet.heartdrop`. The existing `Docs/PrivacyWipeCoverage.md` row and
`knownKeychainServices` entry (`PrivacyWipeCoverageTests.swift:300-304`) already cover it. Only the
quarantine file path is new and must join `wipeForDeleteAll`.

**Also: fix the plan-doc drift.** `Docs/Plan-Bitchat-Adoptions-2026-07-25.md:129` claims the outbox is
"persisted, **sealed at rest**". It is not, today. Update that line when this increment lands.

**Tests:** plaintext→sealed one-way migration; key-missing-with-file-present quarantines the outbox
and deletes the other two; read-back verification failure refuses to seal; wipe removes primary +
quarantine + key.

**Risk (medium, real migration burden):** see O1. Also, every future debugging session on this
subsystem now needs the key to read the file.

---

# Track B — signed prekey (Increments 5-7)

**What problem this actually solves.** The exhaustion story is nearly moot: at
`maxPerFriendPerDay = 3` (`HeartDropOutbox.swift:51`), 16 prekeys last ~6 days, and
`maxSealBundleAge = 7 d` (`HeartDropPeerBundleCache.swift:33`) fires first. Top-up-on-exhaustion is
not a missing feature worth building. The real gap is that **any friend not met in person in the last
7 days gets static-sealed drops forever** — `queueHeart` falls back to `friend.keyAgreementPublicKey`
(`HeartDropService.swift:198-209`), and that same long-term KA private also derives the day tags
(`fetchIncoming` :368-380). One device compromise retroactively opens every static-sealed drop *and*
recomputes every historical day tag. Away-hearts is by definition the feature for friends who are
away, so this is the common case, not the edge.

**What it does not solve, say it out loud:** an SPK is medium-term FS, not per-message FS, and the
retention arithmetic below means its private half lives ~5 weeks — marginally *longer* than today's
one-time keys. **This is a coverage win, not a window win.**

**Wire cost: zero.** `HeartDropSealer` already carries a 16-byte prekey id with all-zeros meaning
static (`HeartDropSealer.swift:42-44, 66-67, 98-104`), `seal` takes an opaque `(id, publicKey)?`, and
`open` resolves any non-zero id through the injected closure without caring where it came from. A
medium-lived signed prekey is just another `(id, publicKey)` pair. If an implementation of this track
needs to edit `HeartDropSealer.swift`, it was implemented wrong — diff that file to check.
`IdentityRangingPayload` is `private` inside `ProximityCoordinator.swift:55-75` and carries
`HeartPrekeyStore.Bundle` — **neither is in FernletDomainModel, so no clean build, no new
PayloadType, no new capability, no CloudKit change.**

## Increment 5 — signed prekey in the local store

**File:** `HeartPrekeyStore.swift`.

```
public struct SignedPrekey: Codable, Equatable, Sendable {
    public let id: UUID
    public let publicKey: Data
    public let created: Date
    public let expires: Date       // rotation deadline, NOT retention deadline
}
public struct Bundle { ...; public let signedPrekey: SignedPrekey? }   // additive OPTIONAL
```

`currentBundle()` (:89) mints/rotates the SPK alongside the one-time batch and attaches the current
one. `privateKey(forPrekeyID:)` (:109) also searches retained SPKs.

**Constants** (values per **O2**): `spkRotation = 7 d`, `spkSealWindow` (sender-side cap, Increment 6),
`spkRetention` (owner keeps a rotated-out private half this long).

**Invariant that makes it correct:**
`spkRetention ≥ spkSealWindow + HeartDropOutbox.entryLifetime (14 d) + createdAtSkewTolerance (1 d)`.
A drop sealed on day X can sit in the outbox 14 days before upload and be fetched later still.
Violating this silently loses hearts — the recipient just fails `open` and returns
(`HeartDropService.openIncoming` :400-407). Concrete: `sealWindow 21 d → retention 36 d`, or
`14 d → 29 d`.

**Risk (HIGH, and it is the whole migration risk of this track):** `StoredState`
(`HeartPrekeyStore.swift:66-68`) must gain `var signedPrekeys: [StoredSignedPrekey]?` — **optional**,
or a hand-written `init(from:)` using `decodeIfPresent`. A non-optional field makes synthesized
`Codable` throw on every existing keychain blob, and `loadState()` (:148-166) classifies an
undecodable blob as corrupt → empty → mint fresh, **stranding the private halves of prekeys already
gossiped**. Every in-flight drop would then fail to open, silently. Land a regression test that
decodes a captured pre-change blob.

## Increment 6 — cache the SPK in its own slot

**File:** `HeartDropPeerBundleCache.swift`.

```
private struct PeerState: Codable {
    var bundle: HeartPrekeyStore.Bundle
    var consumedIDs: Set<UUID>
    var signedPrekey: HeartPrekeyStore.SignedPrekey?   // own monotonicity, own freshness
    var lastUsedAt: Date?
}
```

Two slots, two independent newer-wins comparisons, `maxSealSignedPrekeyAge` separate from
`maxSealBundleAge` (:33). Relax `store()`'s `guard !bundle.keys.isEmpty` (:60) so an SPK-only bundle
is storable **without wiping the one-time slot**. `consumePrekey()` (:89) becomes: fresh unconsumed
one-time → else fresh SPK → else nil, returning `(id, publicKey, isOneTime)`.

**Risk (medium):** do **not** put the SPK in the existing `bundle` slot. A leaner bundle would replace
a richer one and destroy key material, and the `!bundle.keys.isEmpty` guard would silently drop an
SPK-only bundle entirely. Extend — do not merely keep passing — the existing tests
`olderBundleNeverReplacesNewerAndKeepsConsumption` and `staleBundleIsNotSealedTo`
(`Tests/FernletTests/HeartDropTests.swift:380, :401`).

**Ordering note:** this file is rewritten by Increment 2. Do A first.

## Increment 7 — service wiring, audit, invariant test

**Files:** `HeartDropService.swift`, `Tests/FernletTests/HeartDropTests.swift`.

- `queueHeart` (:161) passes the tuple through unchanged.
- Make the local `returnPrekey()` helper (:201-204) explicitly skip non-one-time keys instead of
  relying on the incidental no-op at `HeartDropPeerBundleCache.swift:110-111` (the guard fails today
  by accident; that is the kind of accident a later edit breaks).
- Extend the `heartdrop.queued` audit context (:232) from `"static"`/`"one-time"` to include
  `"signed"`, so the fallback mix is observable in the field. This is also the telemetry that would
  ever justify reopening per-friend prekeys.
- **Invariant test**, same shape as the existing `senderDailyCapMatchesTheReceiverBudget`
  (`HeartDropTests.swift:880`): assert
  `spkRetention ≥ maxSealSignedPrekeyAge + HeartDropOutbox.entryLifetime + createdAtSkewTolerance`.
  Plus a round-trip. Get the scenario right: the SPK is **minted** at day 0 and the drop is **sealed**
  near the end of the seal window (~day 20), then opened at day 34 → success; a drop whose SPK has
  passed retention → clean failure. Do NOT write "seal at day 0, open at day 34": `openIncoming`'s
  skew clamp (`HeartDropService.swift:431-433`) rejects any drop whose signed `createdAt` is older
  than `entryLifetime + createdAtSkewTolerance` (15 d), so that scenario is unreachable at the service
  level and would either fail the test or quietly bypass the clamp by testing only the sealer. What
  the invariant actually protects is the gap between the last legitimate SEAL against an SPK and the
  last legitimate OPEN of a drop made then — which is why retention must exceed
  `maxSealSignedPrekeyAge + entryLifetime + skew`, not just `entryLifetime`.

---

# Track C — coach path (Increments 8-10)

## Coach channel model (owner, 2026-07-26) — READ THIS FIRST

An earlier draft of this plan asked whether the in-person `.trainer` session was wanted at all and
recommended dropping it. **That was wrong, and it inverts this track.** The owner's model:

> The **in-person mesh session is the PRIMARY channel.** Coach and trainee meet, work out together,
> and the coach hands over the next week's workouts plus any recipes. Then repeat, weekly.
> **iMessage + CloudKit are the SECONDARY channel**, for off weeks — if you can't make the in-person
> session, you still get next week's workouts.

Consequences, in order of how much they change:

1. **Increment 10 is promoted from "only if" to BLOCKING.** The three defects it lists are not latent
   any more; they sit on the primary path. Nothing about the coach feature works until they are fixed:
   the non-UWB handshake hang (`ProximityCoordinator.swift:564-580` — a coach or trainee on a
   non-UWB iPhone can never complete the handshake, and `tapToConfirm()` has no UI), the absent
   verification ceremony, and `TrainerExportPayload`'s bound sitting after decrypt instead of before.
2. **A coach verification ceremony is now required work, not a deferred idea.** This is the single
   biggest piece. The QR ceremony is structurally bound to the friend mesh: `beginQRVerification`
   matches on `manualCommitPeer(of:)` i.e. `state == .awaitingManualCommit`, and
   `pendingQRVerifications` is keyed by `PeerSlot.id`, a friend-mesh construct. A coach session has no
   slot. So this is either a coach-side slot equivalent or a second ceremony implementation — and
   whichever it is, **carry the fix from this round's review with it**: the displayed nonce must be
   bound to the specific peer the sheet was opened for, the signature must happen *after* that check,
   and a wrong-peer challenge must be dropped WITHOUT clearing the nonce. That defect is easy to
   reintroduce in a fresh implementation, and on a coach channel the blast radius is larger than on
   the friend mesh.
3. **Trust bootstrap is always in person — and that is a genuine security win.** Because pairing
   happens at a session, the remote channel is only ever used between parties that already verified
   face to face. The CloudKit fallback never has to bootstrap trust, only to carry payloads for an
   already-established pair. That removes the hardest problem from the remote channel and is worth
   stating explicitly in the coach spec, which currently reasons about remote pairing.
4. **The weekly cadence bounds the remote channel's requirements.** The fallback only has to cover a
   missed week, occasionally two. A 14-day record lifetime — the same `HeartDropOutbox.entryLifetime`
   the hearts channel already uses — is a natural fit, so R1's derived-pickup-window rule transfers
   directly rather than needing new constants.
5. **Recipes ride the coach channel too.** That is new scope this plan had not accounted for. Recipes
   currently move over the friend mesh as `PayloadType.recipeShare`
   (`ProximityRecipeShareManager`), which is friend-scoped and consent-gated as a friend feature.
   A coach handing over recipes needs either a coach-scoped reuse of that payload type or its own —
   and the "a coach is NOT a friend" rule means it must not simply borrow the friend path's trust
   policy or consent surface. Decide this before writing the coach session.
6. **Payload size changes the R-list.** A week of workouts plus recipes is orders of magnitude larger
   than a 256-byte heart. `TrainerExportPayload.maxBundleBytes` is 2 MiB; the hearts wire cap is
   8 KiB. R3's "hard size cap enforced before decrypt/inflate" still applies, but the number is a
   coach number, and the inflate-bomb guard matters far more here than it does for hearts.

### ⚠️ This contradicts the coach spec — fix that too

`Docs/FernletCoach-Specification-2026-07-19.md` states the opposite channel priority: §3.3 makes the
hybrid iMessage + CloudKit connection primary, §6's channel-policy table is written around it, and §8
phases the work accordingly. **The spec is now stale on its most load-bearing decision.** Whoever
picks up implementation should revise §3.3, §3.6, §6 and §8 to make the in-person mesh primary and the
remote channel the off-week fallback, before building against it. A pointer has been added at the
spec's §3.3 so a reader of that document is not misled.

## (a) What the coach path already inherits from shared code — with proof

Strictly, *nothing executes* today: `begin(role:mode:)` (`ProximityCoordinator.swift:199`) has three
production call sites, all `.friend` (`MeshNetworkManager.swift:1551`,
`ProximityRecipeShareManager.swift:401`, `PresenceManager.swift:651`). Every `.trainer` call site is a
test. What a future `.trainer` coordinator **would** traverse, mode-blind:

| Inherited | Proof |
| --- | --- |
| Exact-16 fingerprint binding (the de-grindable fix from `75587bd`) | `IdentityService.fingerprintsMatch` (:745-750) requires `count == 16` on both sides; called from `FernletIdentityEnvelope.verify` :202; `handleInbound` (:720) calls `verify` with no mode branch. |
| Sealing-required fail-closed for all four coach payload types | `.trainerPlan, .trainerPlanDelta, .workoutCompletion, .workoutLiveUpdate` are all in `sealingRequiredTypes` (`Wire/FernletIdentityEnvelope.swift:170`). An unsealed coach payload throws on **any** path that calls `verify`, including a future dead-drop opener. |
| Schema-version gating, expiry, signature, recipient check, unknown-type parking | `FernletIdentityEnvelope.verify` :187/:190/:197/:201/:218; coordinator parks unknown types at :741-744. |
| wire2 framing mechanism | `peerSealedPayloadFormat` (:374-382) keys off `supports(.wire2)` from `IdentityRangingPayload.capabilities` (:57-62, populated at :784) — mode-blind. **With a trap, see (b).** |
| `ReplayCache` — but only on a live radio | `handleInbound` :723 passes a non-nil cache. A coach *dead-drop* opener must do what hearts did (`HeartDropService.swift:419` passes `replayCache: nil`, substituting `HeartDropDedupStore`) — the 24 h window cannot cover a plan that sits for days. |
| Privacy wipe of `trainerAuditEvents` | `resetAll` → `proximityTrustVault.apply(peers: [], audit: [])` (`FernletStore.swift:3873`; :4106 is `applySnapshot` doing the opposite); `"proximityTrustVault.apply"` is an enforced token in `PrivacyWipeCoverageTests.wipeManifest` and a documented row in `PrivacyWipeCoverage.md`. |

**NOT inherited: the trust decision.** There are THREE `ProximityTrustPolicy` conformances —
`FriendSessionTrustPolicy.swift:4`, `ProximityTrustVault.swift:7`, and
`extension FernletStore: ProximityTrustPolicy {}` (`FernletStore.swift:4400`) — but all six
production injection sites use `FriendSessionTrustPolicy`. That matters for Increment 9(i):
`ProximityTrustVault.isTrustedProximityPeer` (:46-50) is a real REMEMBERED-trust check, i.e.
coach-grade semantics already exist in-tree and are the natural starting point rather than a
new type. `FriendSessionTrustPolicy`
`isTrustedProximityPeer` returns `true` unconditionally (:25) and the block check reads the **friend**
vault. Injecting it into a coach coordinator is exactly the "a coach is NOT a friend" violation the
coach spec §3.2 forbids. Also not inherited: the QR ceremony (see (b)).

## (b) What is broken today

**Nothing is broken in the coach transport, because none of it is built.** The shipped coach feature
is a file: `TrainerExportView` → `FernletStore.writeTrainerExportFile`
(`App/Fernlet/TrainerExportBuilder.swift:195-205`) writes JSON to `temporaryDirectory` with
`.completeFileProtection` and hands it to `ShareLink`. `TrainerExportView.swift:131-137` says so on
screen. `TrainerExportPayload` (`Wire/TrainerPayloads.swift:23-40`) has zero production call sites.

One **live user-visible** bug, and it is coach-shaped only by name:

- `MoveView.hasRecentCoachInteraction` (`App/Fernlet/MoveView.swift:62-67`) scans `trainerAuditEvents` for
  `.peerAccepted/.envelopeReceived/.envelopeSent` in the last 14 days. That log is misnamed: it is the
  generic proximity audit for **all** modes, written on every state transition, envelope send/receive,
  reject, fail and session end. So it returns `true` for a user who has only ever used the friend
  mesh, turning on the Coach/User plan-source tag (:106, :117, :179) for someone with no coach. It is
  the only production consumer of that log and it is measuring the wrong thing.

Three defects that are unreachable *today* only because no production code starts a `.trainer`
session. Since the in-person session is the PRIMARY coach channel (see "Coach channel model"), these
are **blocking work for the coach feature**, not curiosities — Increment 10 owns them:

- **A non-UWB device can never complete a trainer handshake.** `handleDistance` guards
  `ranging.isHardwareSupported` (`ProximityCoordinator.swift:564`) before the tap gate (:577), so with
  no UWB there is no distance stream and `.awaitingTapConfirmation` (entered at :277) only advances via
  `tapToConfirm()` (:298) — a public API with no UI. The session hangs to timeout.
- **The QR ceremony structurally cannot reach the coach path.** `beginQRVerification`
  (`MeshNetworkManager.swift:1786-1802`) matches slots via `manualCommitPeer(of:)` (:1762), i.e.
  `state == .awaitingManualCommit`. Trainer mode never enters that state. Increment 4 of the last
  round did not "miss" the coach path; it could not reach it.
- **`TrainerExportPayload`'s 2 MiB bound is at the wrong layer.** `isWellFormed` (:38) can only run
  *after* the envelope is decrypted and (under wire2) inflated. The hearts round's lesson was the
  opposite ordering — `HeartDropSealer.open` gates size at :88-89 *before* key agreement, and
  `openIncoming` re-gates at :396 before touching the sealer. 2 MiB is also 256× the heart cap.

Plus one cosmetic: `"caps": mode == .trainer ? "plan,live,delta" : "share"`
(`ProximityCoordinator.swift:1086`) is a stale discovery-info string no reader parses. Whoever wires a
coach coordinator must pass a real `localCapabilities` array (pattern:
`MeshNetworkManager.localCapabilities()`), or wire2 silently degrades to legacy for the whole coach
channel with no failure signal.

**Privacy wipe: no coach gap today.** There is no coach vault, plan store, receipt outbox, or coach
keychain service to miss.

## Increment 8 — fix the live defect, record the do-not-delete decision

**Files:** `App/Fernlet/MoveView.swift:62-67` (+ the three tag sites :106/:117/:179);
`ProximityCoordinator.swift:1086`.

Gate `hasRecentCoachInteraction` on `PlannedWorkout.source == .coach` actually appearing in the user's
days — which is what the tag is about — or hard-code it `false` until a coach vault exists. Separately
drop or correct the stale caps string.

Then write the "do not delete" decision into this doc's locked table (done) so a future tech-debt pass
does not clean up `ProximityMode.trainer` (`FernletDomainModel/ProximityCoordinatorEnums.swift:17`,
freeze-default at `ProximityPersistenceRecords.swift:91-92`) or the four reserved `PayloadType` cases
(`PayloadType.swift:22-25`). Deleting `.trainer` is a FernletDomainModel enum change **and** a
persisted-compat break on every existing trust-vault row.

**Risk:** low. Verify the UX-appearance tests that assert the plan-source tag.

## Increment 9 — coach dead-drop requirements (CHECKLIST ONLY, not built this round)

This is the review checklist for a future coach-dead-drop PR. It is written now because the hearts
round earned every one of these the expensive way and the knowledge decays.

Three asymmetries reshape the list versus hearts: **(i)** a coach is not a friend, so the receive-side
sender gate cannot be `openIncoming`'s "expected sender is an active friend"
(`HeartDropService.swift:414-416`) — it must be "sender is a paired coach in the **coach vault**,
coach-class, with a pinned App Attest receipt"; **(ii)** the channel is asymmetric — coach→trainee
carries plans, trainee→coach carries only system-generated receipts — so two directions with different
budgets, allowlists and consent gates; **(iii)** plans are ~1000× a heart, so the wire cap is its own
constant, not `HeartDropSealer.maxWireByteCount = 8 KiB` (:39).

| # | Requirement (reviewable as a yes/no) | Hearts precedent | Reuse verdict |
| --- | --- | --- | --- |
| R1 | Addressing rotates on a UTC day epoch and is uncorrelatable across days without the pair secret; the HMAC message carries a **role term** for direction asymmetry. | `IdentityService.heartDropTag` / `heartDropDayEpoch` / `heartDropPairSecret` (salt `fernlet.heartdrop.v1`) | Reuse the shape, **new salt** `fernlet.coachdrop.v1`. ⚠️ conflicts with coach spec §3.4's static `channelTag` — see **O6**. |
| R2 | Pickup window is **derived** from record lifetime in code, not hand-written, and covers the continuous-time boundary (`lifetimeDays`, not `−1`). | `HeartDropService.pickupWindowDays` (:62) + the reasoning at :50-61 | Reuse the invariant, not the number. Acceptance test: a record created one second before a UTC midnight is still findable on the final day. |
| R3 | Query pagination follows the cursor; truncation is **logged, never silent**; chunk size small enough that one hostile writer cannot starve other tags in a page. | `HeartDropCloudTransport.fetch` + `heartdrop.fetch.truncated` | Reuse verbatim for any queried leg. |
| R4 | Outer seal is sealed-sender; sender authenticated **only** by the inner signed envelope; hard wire cap enforced **before** ECDH and before inflate. | `HeartDropSealer.open` size gate at :88-89 before :96 key agreement; `openIncoming` re-gate at :396 | Reuse the type with `hkdfSalt` + `maxWireByteCount` parameterized. |
| R5 | Receive-side flood budget keyed on a **receiver-derived, clamped** clock — never a sender-supplied value. | `openIncoming` :429-440 and the comment at :423-428 explaining why `sentAtDayKey` made the bound vacuous (~10⁸ buckets) | Reuse the mechanism verbatim; re-derive numbers per direction. Receipts likely key on `(planID, dayIndex)` — a stronger bound than a daily counter (see O3-adjacent decision). |
| R6 | Durable dedup bounded by **size as well as age**, evicting oldest-first — never `removeAll`. | `HeartDropDedupStore` (:243-347) and the explicit note at :250-252 that a wholesale reset is itself an attack | Reuse the class; make `maxAcceptedPerSenderPerDay` (:249) an instance property. |
| R7 | A **sender-side** cap derived in code from the receiver's budget, so nothing is uploaded that will be discarded. | `HeartDropOutbox.maxPerFriendPerDay = HeartDropDedupStore.maxAcceptedPerSenderPerDay` (:51) | Reuse the derivation so the two can never drift. |
| R8 | Consent gated **at the service seam** and re-checked at **every** await boundary. | `runSync` (:306-321), `flush` (:325), `fetchIncoming` (:386), `cleanup` (:461) | Reuse the pattern, but **two gates**: `isPaired(coach) && (inbound || receiptConsent(coach))`. |
| R9 | Purge of our own uploaded records on consent withdrawal, **derived** (never a process flag) so it survives relaunch and fires when consent arrives from another device. | `purgeDeadDrop` (:483-521) incl. capture-before-await + `removeUnchanged` + generation guard; app-side retry `ContentView.swift:864-876` | Reuse exactly, for the trainee's receipt records. |
| R10 | Registered in `Docs/PrivacyWipeCoverage.md` with an **enforced token** in `PrivacyWipeCoverageTests.wipeManifest`, in the **same commit** as the store; any new keychain service also joins `knownKeychainServices` (:300-304). Remote purge **before** local wipe. | The doc's contract + the hearts rows | Reuse the mechanism verbatim. |
| R11 | **New — no hearts analogue.** Coach spec §3.6's payload-type allowlist enforced at the seam on **send and on dispatch**, with an executable channel-policy test. | — | Reimplement. `sealingRequiredTypes` fails an *unsealed* coach payload closed, but nothing stops a *sealed* `friendPhoto` riding the coach channel. |
| R12 | **New.** Unknown `CoachPlan` schema versions freeze/park and tell the user to update — never guess. | `EnumDecodeCompat`; envelope parking at `FernletIdentityEnvelope.swift:218` | Reuse the pattern. ⚠️ `CoachPlan v1` is a new FernletDomainModel type with enums ⇒ **CLEAN build**. |

**Shared-infrastructure verdicts, for when that PR exists** (do *not* pre-build them now — see "Not
doing"): generalize `HeartDropSealer` → `SealedDropSealer` (lift `hkdfSalt` :43 and
`maxWireByteCount` :39 to parameters; keep `HeartDropSealer` as a wrapper pinning today's values and
prove bit-identity with a fixed-vector test, because the current wire is already in TestFlight hands
and a silent salt change breaks delivery with no error surface); generalize `HeartDropDedupStore`
(one static → instance property); generalize `HeartDropTransporting`
(`FernletDomainModel/HeartDropTransport.swift`) — keeping the seam in FernletDomainModel is what
preserves the S3 wall, and `S3BoundaryTests.swift:226-227` enforces both directions mechanically.
**Copy `HeartDropOutbox` rather than genericize it** — it is hearts-shaped in five constants and a key
type, and genericizing obscures the capture-before-await purge and `removeUnchanged`'s two-collection
trick (:142-163, with the comment at :144-147 explaining why a `[UUID: String?]` subscript would erase
keys). ~150 duplicated lines plus a shared fixture test asserting both implementations agree is the
right price. **Keep `HeartDropService` separate** — it is pure policy and every policy differs; a
shared service would be a `switch channel` in every method.

The closed-source Coach app argues *for* this split: it links FernletKit under Apache-2.0, so it needs
the mirror-image sealer/dedup/transport from the same source, and must not fork the crypto.

### Where `.trainer` actually runs (owner, 2026-07-26)

**Trainer mode comes from the separate coaching app.** That is a constraint on this whole track, not a
detail, and it changes what "apply the hardening to the coach mesh" can even mean:

- **This repo DOES need a `.trainer` coordinator — but probably only the browser/client half.** Today
  no production code calls `begin(mode: .trainer)` (`MeshNetworkManager.swift:1551`,
  `PresenceManager.swift:651`, `ProximityRecipeShareManager.swift:401` are all `.friend`). Since the
  in-person session is the primary channel (see "Coach channel model") and the coach app is the one
  that advertises, Fernlet is the **browser** side: it discovers the coach, completes the handshake and
  the ceremony, and receives the week's plan and recipes. Decide the role split explicitly and write it
  down — `begin(role:mode:)` takes both, and getting it backwards means two advertisers that never
  find each other.
- **Half the implementation is in a repo this plan cannot review.** A defect in the coach app's
  dead-drop opener is invisible to Fernlet's test suite, its wall check, and its review rounds. So the
  hardening has to travel by two mechanisms, and only one of them is code:
  1. **Shared code** — the sealer, dedup, and transport protocol linked from FernletKit, so both sides
     run the *same* crypto and the same size/tag/window logic. This is why the generalization verdicts
     above matter: anything the coach app reimplements is a place the two can silently disagree, and a
     wire-format disagreement here fails as "no hearts/plans ever arrive", with no error to see.
  2. **The R1-R12 checklist** — for everything that is policy rather than code (consent gating, purge
     on withdrawal, wipe registration, budgets). The coach app must be reviewed against it
     independently; Fernlet's green suite says nothing about the coach side.
- **The asymmetry is real: only one side is auditable.** Fernlet is open source and gets adversarial
  review rounds like the one that produced this plan. The Coach app is closed. So the trainee side
  must be **fail-closed against a misbehaving coach** rather than trusting a shared-lineage
  implementation — every R1-R12 receive-side bound (size cap before decrypt, receiver-clocked budget,
  bounded dedup, sender-must-be-the-expected-coach) is load-bearing precisely because the counterpart
  cannot be inspected. Write them as if the coach app were hostile, not merely buggy.
- **Version skew becomes a first-class concern.** Two independently shipped apps mean a coach on an
  older FernletKit and a trainee on a newer one, in both directions. R12's freeze/park rule and the
  capability handshake are the mechanisms; neither has ever been exercised across a release boundary
  the way two separate App Store apps will exercise it.

## Increment 10 — coach coordinator defects (BLOCKING: this is the primary channel)

Promoted from optional on 2026-07-26. These are not latent defects on a path that may never ship —
they are on the path the coach feature runs on. In dependency order:

1. **Non-UWB handshake hang.** `handleDistance` guards `ranging.isHardwareSupported`
   (`ProximityCoordinator.swift:564`) before the tap gate (:577), so with no UWB there is no distance
   stream and `.awaitingTapConfirmation` (entered at :277) only advances via `tapToConfirm()` (:298) —
   a public API with **zero production callers**. The session hangs to timeout. Fix by giving the
   trainer path the friend path's `awaitingManualCommit` fallback, or by building a real tap UI. This
   is also the precondition for (2), because the QR ceremony keys off `awaitingManualCommit`.
   **Note this is not a rare edge case for a coach feature**: the coach and the trainee each need a
   UWB-capable iPhone for the current path to work at all.
2. **A verification ceremony for the coach session.** See "Coach channel model" item 2 above for the
   structural problem (slot-bound) and, more importantly, for the defect that must not be
   reintroduced (per-peer nonce binding, sign-after-check, wrong-peer drop must not clear).
3. **Real capabilities at construction.** `"caps": mode == .trainer ? "plan,live,delta" : "share"`
   (`ProximityCoordinator.swift:1086`) is a stale discovery-info string nothing parses. A coach
   coordinator must pass a real `localCapabilities` array (pattern: `MeshNetworkManager
   .localCapabilities()`) or **wire2 silently degrades to legacy for the entire coach channel with no
   failure signal** — the exact silent-downgrade class this round's review already had to fix once.
4. **`TrainerExportPayload`'s bound moves before the crypto.** `isWellFormed` (:38) runs only after
   the envelope is decrypted and (under wire2) inflated. The hearts round landed the opposite
   ordering — `HeartDropSealer.open` gates size at :88-89 before key agreement, and `openIncoming`
   re-gates at :396. Coach payloads are far larger, so the inflate-bomb exposure is correspondingly
   worse.
5. **A trust policy that is not the friend policy.** All six production injections use
   `FriendSessionTrustPolicy`, whose `isTrustedProximityPeer` returns `true` unconditionally (:25) and
   whose block check reads the **friend** vault. Injecting it into a coach coordinator is the "a coach
   is NOT a friend" violation the coach spec §3.2 forbids. `ProximityTrustVault` (:46-50) already
   implements remembered-trust semantics and is the natural starting point.

**Sequencing note:** (1) and (5) are prerequisites for a working session; (2) is the security gate on
it; (3) and (4) are correctness fixes that can land alongside. None of this touches
FernletDomainModel, so no clean build is implied — with the exception of any new coach payload type,
which does.

---

## Cross-cutting

- **FernletDomainModel clean-build hazard: this round does not trip it.** No enum or struct in
  `FernletKit/Sources/FernletDomainModel` changes. `QueueOutcome`/`DeliveryProblem` are ProximityKit;
  `HeartPrekeyStore.Bundle` and `IdentityRangingPayload` are ProximityKit (the latter `private`).
  Still do one clean build after Increment 3 — same mechanism, cross-module enum layout, and one build
  is cheap. Anything in the deferred list (coach `PayloadType`, `CoachPlan v1`, a `HeartDropRecord`
  field) **does** trip it and must land in a single clean-build commit.
- **Compat.** Increment 5's `StoredState` field must be optional/`decodeIfPresent` (the one hard
  migration risk in the round). Increment 4 is a one-way plaintext→sealed file migration. Old peers'
  bundles decode with `signedPrekey == nil` and keep working; new bundles' extra key is ignored by old
  decoders. No envelope schema bump, no CloudKit schema change, no capability token.
- **S3 wall.** Nothing here crosses it. ProximityKit gains a UIKit notification observer (UIKit is
  already imported in four ProximityKit files; the package is iOS-only). ProximityKit still never
  imports CloudKit; the transport seam stays in FernletDomainModel. Run `Scripts/spm-wall-check.sh`
  plus `Tests/FernletTests/S3BoundaryTests` before merge.
- **Test cadence.** Targeted `HeartDropTests` / `HeartDropAppWiringTests` during increments; full
  suite in batches (lock suite dominates, ~7 min total) + wall check + one clean build before merge.
  New test seam: a `readData:` injection on the three stores, defaulted so no existing call site
  breaks (`HeartDropTests.swift` constructs them 29 times).
- **Shared worktree discipline.** Pathspec commits only; never sweep the xcscheme plist / AGENTS.md.
- **Doc updates on merge:** `Plan-Bitchat-Adoptions-2026-07-25.md:100` (S3BoundaryTests CloudKit rule
  now exists) and :129 ("sealed at rest" becomes true only at Increment 4).

## Not doing / deferred

| Item | Why |
| --- | --- |
| **Per-friend disjoint one-time prekey sets + consume-on-open** (research "Design B") | It tightens the FS window on drops that *already have* FS and does nothing about the drops that have none — which is the actual gap. Cost is 3-4 sessions of the expensive kind: a keychain layout migration (single blob → per-friend rows) with a legacy row that must stay resolvable and consume-exempt for ≥21 days after changeover; a closure-signature change through two managers and `FernletStore.swift:247`; a new PayloadType (clean-build hazard) because the **mesh intro cannot know the peer** (`currentDiscoveryInfo()` publishes no `fp`); and an irreversible delete-on-open whose failure mode is hearts that silently never arrive, days later, on someone else's device. What it buys: the FS window on already-FS drops drops from ≤32 d to first-open + 48 h, protecting "X sent Y affection on day D" for a few dozen hearts — while day-tag linkage survives regardless, because tags derive from the static KA key. Poor return. **Reopen only if** the `heartdrop.queued` audit (Increment 7) shows a meaningful share of `"static"` sends to friends met via presence — and then take presence-only per-friend + consume-on-open, skipping the mesh PayloadType entirely. |
| **`prekeyBundle` PayloadType + the mesh commit-hook gossip** (`MeshNetworkManager.noteSlotCommittedForShop`) | Only needed by per-friend prekeys on the mesh path. Costs the second FernletDomainModel clean build this round deliberately avoids. |
| **Relaxing sidecar file protection to `completeUntilFirstUserAuthentication`** | Strict privacy loss until a background writer exists: it hands an AFU-state attacker both the ciphertext and the key that opens it. bitchat relaxes because it genuinely wakes on BLE; Fernlet does not wake at all. Push does not *justify* the relaxation — it merely makes it unavoidable for whichever store a woken pass must write. |
| **Push / `CKQuerySubscription` for hearts** | See **O3**. Received hearts surface only in-app, so a push-woken fetch delivers into a UI nobody is looking at; the foreground `syncNow()` would have fetched it seconds later anyway. And subscriptions match a static predicate while tags rotate daily across 15 live tags per friend. Needs a feasibility spike before it is treated as a planned v2. Note Increments 1-4 are the prerequisite for *any* background path (a `BGAppRefreshTask` hits the identical locked-device problem), so they should land regardless of how O3 resolves. |
| **Pre-generalizing `SealedDropSealer` / `SealedDropDedupStore` / `SealedDropTransporting`** | The generalizations are right but doing them without a second consumer means guessing the parameterization *and* re-risking an already-deployed wire format for no delivered feature. Do them inside coach P1, when the coach service exists to pin the shape. |
| **Coach dead-drop (the off-week fallback), coach vault, coach trust policy** | Still deferred, but the ordering changed: it is now the SECONDARY channel, so it follows the in-person session rather than leading. O6 is resolved (coarse-rotating tag). The App Attest gate (coach spec §3.2/§8) is worth re-examining — with pairing always happening in person, the remote channel never bootstraps trust, which is much of what attestation was there to solve. Increment 9 is the checklist for when it unblocks. |
| ~~Live `.trainer` proximity session, coach QR ceremony, the coordinator defects~~ | **NO LONGER DEFERRED (owner, 2026-07-26).** The in-person session is the PRIMARY coach channel, so this is Increment 10 and it is blocking. The instinct behind the old entry still holds though: fix these *as part of* the session work, in one branch, so the code never looks alive before it is. |
| **`ClosenessLedger` / `FriendStateCache` / `ModerationLedger` sidecar adoption** | Same load-any-failure-as-empty shape, materially lower stakes. Tracker line, not this round. |
| **Design "C" — bundle refresh over the dead-drop itself** | `HeartDropTransporting` is already a generic `{tag, payload}` seam, so a bundle-refresh record under a separate tag namespace needs **zero** protocol or wall change. This — not per-friend disjointness — is what would make forward secrecy hold for the friends away-hearts exists for, since re-gossip today only happens in person. Costs a second public-DB record type (owner console promotion), a polling budget, and a real privacy call on what a bundle record under a pairwise tag reveals to someone who already holds that tag. **Deserves its own design round.** |
