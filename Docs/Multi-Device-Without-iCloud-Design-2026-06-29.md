# Multi-Device Without iCloud — Design Review

**Status:** design review / options, 2026-06-29 (revised same day, after Increment 3). Captures the problem,
the grounded options, and a recommended phased path so multi-device usage degrades gracefully when iCloud
sync is off — with an offline **mesh sync** as the eventual goal. **Update:** the items/recipes append-only
fix from Phase 1 has since shipped (commit `3250d33`); remaining work is the warning, owned-device pairing,
and the per-row day split.

## Problem

Fernlet supports **local-only storage** (iCloud sync off) as a first-class privacy choice. But with iCloud
off there is **no sync path between a user's own devices** — each device is an independent island that
diverges silently. Affected data: day history, settings, the per-row stores (custom items, coin ledger,
recipes), and the sealed narratives. The coin ledger, for example, mints earn rows from *its own* device's
day history and tracks *its own* spends, so two un-synced devices show different balances.

The owner wants, at minimum, to **warn the user on a second device** that another device already exists and
that without iCloud there will be divergence — and is interested in **using the proximity mesh to sync
devices offline**.

## The hard constraint: detection needs a server *or* co-location

Without a server you can only learn another device exists if it (a) left a trace **in CloudKit** (an iCloud
account exists, even with sync disabled) or (b) is **physically near** (mesh). A user who never used iCloud
on any device is undetectable until the devices meet. So "warn that another device exists" has two regimes.

`CloudKitDataService.detectExistingData()` ([CloudKitSync/CloudKitDataService.swift:167](../FernletKit/Sources/CloudKitSync/CloudKitDataService.swift))
already queries CloudKit for data written by another device. It runs in onboarding
([OnboardingStorageChoiceView.swift:108](../Fernlet/OnboardingStorageChoiceView.swift)) and is also already
surfaced in Privacy settings as a **"Cloud records" count card** ([PrivacyDataSettingsView.swift:884](../Fernlet/PrivacyDataSettingsView.swift)) —
but that card is deletion-oriented (how much is in iCloud), **not** re-run on the sync-disable action and not
framed as a divergence warning. So the detection machinery exists; what's missing is wiring it to a
second-device warning. `iCloudAvailable = ubiquityIdentityToken != nil`;
`StoragePreferences.iCloudSyncEnabled` lives in the keychain (default off).

## Grounded inventory

**Device identity (for same-user pairing) — mostly already there.** Stable per-device Ed25519 signing key
(keychain, `ThisDeviceOnly`) is a strong device id, and a **backup-escrow X25519 key already syncs across a
user's devices via iCloud Keychain** ([ProximityKit/IdentityService.swift:74](../FernletKit/Sources/ProximityKit/IdentityService.swift))
— "multi-device same-user" is already a modeled concept. Gap: `ProximityTrustedPeerRecord` has no
relationship type, so a paired own-device is treated like a friend. Add `relationshipType: .ownedDevice`.

**Mesh transport — proven for bulk.** The friend-photo manifest+chunk flow and the sealed-backup chunker
(250-record segments) already move large data device-to-device over MultipeerConnectivity (reliable). A
"data sync" payload mirrors that pattern; no transport research blocker.

**Mergeability of each data class — the crux for live sync:**

| Data | Merge semantics today | Mesh-ready? |
|---|---|---|
| **Coin ledger** | append-only, union-merge by id (`CoinEconomy.deduplicatedByID`) | ✅ already done — the template |
| **Custom items / recipes** | per-row **append-only upsert** (`upsert` touches only listed ids; dedup-by-id on load) | ✅ done (Increment 3) — was a full-replace clobber, now mirrors the coin ledger |
| **Day history** | one blob; `mergingRemoteDays` unions by `dateKey` only, same-day edits drop the remote | ❌ needs per-row day split or item-level merge |
| **Settings** | last-writer-wins blob, no field merge | ❌ needs per-key store or field-level policy |
| **Journal / cycle / intimacy narratives** | sealed, encrypted, **local-only** | 🔒 exclude from live sync; move via backup-transfer |

**Sealed backup over mesh.** The backup is **sealed-narratives only** (Tier-2 memories + cycle notes),
**not** whole-account ([SealedBackupCoordinator.swift:427](../Fernlet/SealedBackupCoordinator.swift)), and
restore needs the escrow key, which today syncs via **iCloud Keychain** — so a backup-transfer is *not yet
truly offline*. Making it offline means exchanging the escrow public key over the mesh handshake.

## Latent bug surfaced — now fixed (Increment 3, commit `3250d33`)

As originally written this section flagged a *live* bug: the CloudKit `CustomItemRepository` and recipe store
used a **full-replace `save()`** that deleted every row not in the in-memory set, and those services are not
reloaded after a remote CloudKit merge — so two devices both adding items could clobber each other's
additions over iCloud, not just over mesh. **This is resolved.** Both stores are now **append/upsert-only**
([CustomItemRepository.swift:51](../FernletKit/Sources/CloudKitSync/CustomItemRepository.swift),
[SavedRecipe.swift:162](../FernletKit/Sources/CloudKitSync/SavedRecipe.swift)): `upsert` fetches only the ids
it is handed (predicate `IN`) and never deletes unlisted rows, `delete(ids:)` removes only the listed ids,
and dedup-by-id happens in the service on load — mirroring the coin ledger. (The remaining full-write
`save()` on the **local** file-based recipe repo is single-device with no merge, so it is fine.) This was the
items/recipes half of Phase 1 below; only the warning remains.

## Options

- **A — Warning (cheap, ship first).** A1 proactive ("won't merge without iCloud") on the local-only /
  sync-off path (always works). A2 specific via `detectExistingData()` post-onboarding + on sync-disable
  (machinery exists). A3 opportunistic mesh detection when your two devices meet (needs `.ownedDevice`).
- **B — Manual encrypted export/import** (file / AirDrop). Point-in-time, no auto-merge. Low effort escape
  hatch; whole-account export would be new (today's backup is narratives-only).
- **C — Mesh *transfer* of the encrypted backup** (your idea, conservative). Point-in-time clone for
  new-device setup; reuses backup+chunking. Caveats: narratives-only today + escrow needs iCloud Keychain.
  ~2–3 days iCloud-assisted; ~1 week truly offline (escrow over mesh).
- **D — Mesh *live merge* sync** (your idea, the prize). Coins already merge and items/recipes now do too
  (append-only, done); days still need the per-row split; settings need a merge policy; narratives stay
  local. High effort, phased — but every piece rides the per-row/union-merge direction already chosen.

## Recommended phased path

1. **Now (small):** ~~convert custom-items & recipes to **append-only**~~ — **done** (Increment 3, commit
   `3250d33`): fixed a live iCloud clobber bug *and* unblocked mesh. Still to do: warning A1+A2.
2. **Phase 2:** owned-device pairing (`relationshipType: .ownedDevice` on the trust vault) + mesh
   backup-**transfer** (Option C) for new-device setup; enables warning A3. Decide whether to extend the
   backup to whole-account.
3. **Phase 3:** mesh **live merge** sync (Option D) on top of the per-row day split
   ([Day-PerRow-Split-Plan-2026-06-29.md](Day-PerRow-Split-Plan-2026-06-29.md)), with a settings merge
   policy. Narratives travel only via the backup-transfer path.

**Cross-cutting:** the per-row, union-mergeable architecture (coin ledger is the template) is what makes all
of this tractable. Of the two load-bearing prerequisites, **append-only stores** are now **done** (coins,
items, recipes); the **per-row day split** remains — so "we want offline mesh sync" is itself an argument to
prioritize it.
