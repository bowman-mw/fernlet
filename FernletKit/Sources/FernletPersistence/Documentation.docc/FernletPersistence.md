# ``FernletPersistence``

The Layer-2 persistence contract of FernletKit: the repository protocols every backing store implements, the ``FernletSnapshot`` aggregate they serialize, and the sanitize-barrier wrapper types that keep un-stripped sensitive data out of anything that can sync.

## Overview

FernletPersistence contains no storage code at all — it is a pure contract module. It defines the one aggregate value type the diary persists (``FernletSnapshot``), the abstract repository seam over it (``FernletRepository`` and its ``RemoteChangePublishingRepository`` refinement), five per-row store contracts (``DayRecordRepositoring``, ``CoinLedgerRepositoring``, ``MilestoneLedgerRepositoring``, ``CustomItemRepositoring``, ``SavedRecipeRepositoring``), and the privacy-strip wrappers those seams require (``SanitizedSnapshot``, ``SanitizedDay``, ``DayRecordUpsert``). The concrete implementations live one layer up: `LocalFernletRepository` (local JSON, in `LocalPersistence`) and `CoreDataFernletRepository` plus the five per-row repositories (Core Data + iCloud, in `CloudKitSync`). The app's `FernletStore` selects between the two blob repositories via `StoragePreferences`, and the store-side services in `StoreCore` (`SnapshotSaveCoordinator`, `SavedRecipeService`, `CoinLedgerService`, `MilestoneLedgerService`, `CustomItemService`) are all written against these protocols — never against a concrete store — which is what keeps `StoreCore` and `DiaryStore` free of any `CloudKitSync` dependency.

The module's most load-bearing idea is the **sanitize barrier**, the data-side analogue of the compiler import wall. The repository write methods do not accept raw values: ``FernletRepository/saveSnapshot(_:)`` requires a ``SanitizedSnapshot``, ``FernletRepository/updateDay(_:for:todayKey:)`` requires a ``SanitizedDay``, and a synced day row is built through ``DayRecordUpsert``'s sanitized mint. Those wrapper types have private initializers, so the only way to obtain one in production is through a `sanitizing` factory that applies the storage privacy strip: sealed-journal text is blanked (today's and previous journals), the sensitive `cycle`/`intimate` health-context fields are nil'd, and cycle-derived `periodPhase` is stripped from every stored daily score. An un-stripped snapshot therefore cannot reach a potentially iCloud-synced blob *by construction*, regardless of which conformer is active or how a call site is written. The strip itself is factored into one shared per-day helper so the blob path and the per-day path cannot drift.

That barrier is also this module's relationship to the S3 privacy wall. In the package graph (`FernletKit/Package.swift`), FernletPersistence sits at Layer 2 with a single in-package dependency, `FernletDomainModel` — and it is itself a declared dependency of `CloudKitSync`, one of the two walled consumers. So this module is *outside* the wall: everything it defines is nameable by sync code, and nothing in it may reference the sealed `Private*` stores (it doesn't, and the `DIAGNOSE_MISSING_TARGET_DEPENDENCIES=YES_ERROR` enforcement would make a forbidden import a hard build error). The wall keeps sync code from importing sealed *types*; the sanitize barrier keeps sealed *data* — journal plaintext, cycle/intimacy fields — out of the values sync code is handed. The two mechanisms are complementary halves of the same privacy guarantee. Sealing state itself (which journal IDs are sealed) lives app-side and is passed into the mints as plain data.

The five per-row contracts encode the multi-device merge strategy. The snapshot blob is effectively last-writer-wins, so anything that must survive two devices writing concurrently is carved into its own row store whose contract is **append/upsert-only**: `upsert`/`append` touch only the rows they are handed and never delete rows they didn't receive, so rows union-merge across devices and one device can never clobber another's synced rows. Each contract carries a deliberate variation: ``DayRecordRepositoring`` splits the day history into per-day rows (which is what allowed the old 370-day blob cap to be removed), ``MilestoneLedgerRepositoring`` still has no delete API on the protocol — the milestone row delete (`deleteAll()`, added 2026-08-20 when the wipe stopped keeping the milestone trail, reversing the earlier survive-a-reset rule) lives only on the concrete CloudKitSync conformer, reachable only by the app's deletion funnel — and the others (`deleteAll`) reserve whole-store deletion for a full account reset. Several of these replaced earlier full-replace `save(_:)` APIs that carried latent cross-device clobber bugs — the contracts now make the safe behavior structural.

Concurrency: the target declares no `defaultIsolation`, so the module default is nonisolated. ``FernletRepository`` and the value types (``FernletSnapshot``, the sanitized wrappers, ``DayRecordUpsert``) are nonisolated; the five per-row protocols and ``RemoteChangePublishingRepository`` are explicitly `@MainActor`, matching their main-actor callers in `StoreCore` and the app. Persistence failure is signaled by `Bool` returns on the write methods (all `@discardableResult`); remote iCloud changes surface only through the ``RemoteChangePublishingRepository`` refinement, which `SnapshotSaveCoordinator` discovers by dynamic cast — a purely local repository simply doesn't conform.

## Topics

### The repository contract

- ``FernletRepository``
- ``RemoteChangePublishingRepository``

### The persisted aggregate

- ``FernletSnapshot``

### The storage privacy strip

- ``SanitizedSnapshot``
- ``SanitizedDay``

### Per-row synced store contracts

- ``DayRecordRepositoring``
- ``DayRecordUpsert``
- ``CoinLedgerRepositoring``
- ``MilestoneLedgerRepositoring``
- ``CustomItemRepositoring``
- ``SavedRecipeRepositoring``
