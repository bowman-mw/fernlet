# Multi-Device Without iCloud — Design Review

**Status:** design review / options, 2026-06-29. No code yet. Captures the problem, the grounded options,
and a recommended phased path so multi-device usage degrades gracefully when iCloud sync is off — with an
offline **mesh sync** as the eventual goal.

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
already queries CloudKit for data written by another device — but it is wired **only into onboarding**
([Fernlet/Onboarding/OnboardingStorageChoiceView.swift](../Fernlet/Onboarding/OnboardingStorageChoiceView.swift)),
not re-checked when a user later turns sync off. `iCloudAvailable = ubiquityIdentityToken != nil`;
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
| **Custom items / recipes** | per-row but **full-replace (delete-unlisted)** in `save()` | ⚠️ latent clobber (see below) → convert to append-only |
| **Day history** | one blob; `mergingRemoteDays` unions by `dateKey` only, same-day edits drop the remote | ❌ needs per-row day split or item-level merge |
| **Settings** | last-writer-wins blob, no field merge | ❌ needs per-key store or field-level policy |
| **Journal / cycle / intimacy narratives** | sealed, encrypted, **local-only** | 🔒 exclude from live sync; move via backup-transfer |

**Sealed backup over mesh.** The backup is **sealed-narratives only** (Tier-2 memories + cycle notes),
**not** whole-account ([SealedBackupCoordinator.swift:427](../Fernlet/SealedBackupCoordinator.swift)), and
restore needs the escrow key, which today syncs via **iCloud Keychain** — so a backup-transfer is *not yet
truly offline*. Making it offline means exchanging the escrow public key over the mesh handshake.

## Latent bug surfaced (fix regardless of mesh)

`CustomItemRepository.save()` and `SavedRecipeRepository.save()` **delete every row not in the in-memory
set**, and those services are not reloaded after a remote CloudKit merge — so **two devices both adding
items can already clobber each other's additions over iCloud today**, not just over mesh. The coin ledger
was deliberately made append-only to avoid exactly this. Converting items/recipes to the same append-only
pattern is small, fixes a live iCloud bug, and is a free step toward mesh-readiness.

## Options

- **A — Warning (cheap, ship first).** A1 proactive ("won't merge without iCloud") on the local-only /
  sync-off path (always works). A2 specific via `detectExistingData()` post-onboarding + on sync-disable
  (machinery exists). A3 opportunistic mesh detection when your two devices meet (needs `.ownedDevice`).
- **B — Manual encrypted export/import** (file / AirDrop). Point-in-time, no auto-merge. Low effort escape
  hatch; whole-account export would be new (today's backup is narratives-only).
- **C — Mesh *transfer* of the encrypted backup** (your idea, conservative). Point-in-time clone for
  new-device setup; reuses backup+chunking. Caveats: narratives-only today + escrow needs iCloud Keychain.
  ~2–3 days iCloud-assisted; ~1 week truly offline (escrow over mesh).
- **D — Mesh *live merge* sync** (your idea, the prize). Coins already merge; items/recipes need the
  append-only fix; days need the per-row split; settings need a merge policy; narratives stay local.
  High effort, phased — but every piece rides the per-row/union-merge direction already chosen.

## Recommended phased path

1. **Now (small):** warning A1+A2; convert custom-items & recipes to **append-only** (fixes a live iCloud
   clobber bug *and* unblocks mesh).
2. **Phase 2:** owned-device pairing (`relationshipType: .ownedDevice` on the trust vault) + mesh
   backup-**transfer** (Option C) for new-device setup; enables warning A3. Decide whether to extend the
   backup to whole-account.
3. **Phase 3:** mesh **live merge** sync (Option D) on top of the per-row day split
   ([Day-PerRow-Split-Plan-2026-06-29.md](Day-PerRow-Split-Plan-2026-06-29.md)), with a settings merge
   policy. Narratives travel only via the backup-transfer path.

**Cross-cutting:** the per-row, union-mergeable architecture (coin ledger is the template) is what makes all
of this tractable. The two already-planned items — the **per-row day split** and **append-only stores** —
are the load-bearing prerequisites, so "we want offline mesh sync" is itself an argument to prioritize them.
